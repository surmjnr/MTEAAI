# ai_server_optionD_fixed.py
"""
AI server - Option D (cleaned)
Endpoints:
  POST /ingest    -> append batch of candles to live weekly buffer
  POST /predict   -> submit a single candle, append to live buffer, return prediction
  POST /train     -> append weekly buffer to historical and start background retrain
  GET  /status    -> health + model status + metadata
"""
import os, time, json, threading, shutil
from datetime import datetime, timedelta
from flask import Flask, request, jsonify
import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import accuracy_score, roc_auc_score
from joblib import dump, load

# ----------------- Configuration -----------------
BASE_DIR = os.path.abspath(os.path.dirname(__file__))
DATA_FOLDER = os.path.join(BASE_DIR, "data")            # historical CSVs saved here
WEEKLY_FOLDER = os.path.join(BASE_DIR, "weekly")       # live-weekly buffers per symbol_tf
MODEL_FOLDER = os.path.join(BASE_DIR, "models")
BACKUP_FOLDER = os.path.join(MODEL_FOLDER, "backup")

os.makedirs(DATA_FOLDER, exist_ok=True)
os.makedirs(WEEKLY_FOLDER, exist_ok=True)
os.makedirs(MODEL_FOLDER, exist_ok=True)
os.makedirs(BACKUP_FOLDER, exist_ok=True)

# Prefer ensemble model files; fallback to single model file names if present
MODEL_FILES_ENSEMBLE = {
    "long": os.path.join(MODEL_FOLDER, "model_long.pkl"),
    "mid":  os.path.join(MODEL_FOLDER, "model_mid.pkl"),
    "short":os.path.join(MODEL_FOLDER, "model_short.pkl")
}
SCALER_FILES_ENSEMBLE = {
    "long": os.path.join(MODEL_FOLDER, "scaler_long.pkl"),
    "mid":  os.path.join(MODEL_FOLDER, "scaler_mid.pkl"),
    "short":os.path.join(MODEL_FOLDER, "scaler_short.pkl")
}

# Single-model fallback (older setups)
SINGLE_MODEL = os.path.join(MODEL_FOLDER, "eurusd_model.pkl")
SINGLE_SCALER = os.path.join(MODEL_FOLDER, "scaler.pkl")

LIVE_BUFFER_SIZE = 1000
ENSEMBLE_WEIGHTS = {"short":0.5, "mid":0.3, "long":0.2}
MIN_ROWS_FOR_RETRAIN = 200
RETRAIN_LOCK = threading.Lock()
METADATA_FILE = os.path.join(MODEL_FOLDER, "metadata.json")
INCREMENTAL_RETRAIN = True  # if True, only retrain on data since metadata.last_retrain when present
print("[DEBUG] METADATA_FILE =", METADATA_FILE)
RETRAIN_LOG = os.path.join(MODEL_FOLDER, "retrain_log.txt")

app = Flask(__name__)
app.config['JSON_SORT_KEYS'] = False

# in-memory cache
_loaded = {"long": None, "mid": None, "short": None, "single": None}
_scalers = {"long": None, "mid": None, "short": None, "single": None}
_last_loaded_time = 0.0

# Thread safety: protect global model/scaler access
MODEL_ACCESS_LOCK = threading.Lock()

def log(msg):
    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    print(f"[AI {ts}] {msg}")

# ----------------- Weekly live buffer helpers -----------------
def weekly_buffer_path(symbol, timeframe):
    name = f"{symbol}_{timeframe}.csv"
    return os.path.join(WEEKLY_FOLDER, name)

def append_to_weekly(symbol, timeframe, rows):
    path = weekly_buffer_path(symbol, timeframe)
    df_new = pd.DataFrame(rows)
    if df_new.empty:
        return 0
    df_new.rename(columns={'t':'time','o':'open','h':'high','l':'low','c':'close','v':'volume'}, inplace=True)
    df_new['time'] = pd.to_datetime(df_new['time'], unit='s')
    if os.path.exists(path):
        try:
            df_old = pd.read_csv(path, parse_dates=['time'])
            df = pd.concat([df_old, df_new], ignore_index=True)
        except Exception as e:
            log(f"append_to_weekly: failed to read existing weekly file {path}: {e}")
            df = df_new
    else:
        df = df_new
    df.drop_duplicates(subset=['time','open','high','low','close'], keep='last', inplace=True)
    df.sort_values('time', inplace=True)
    if len(df) > LIVE_BUFFER_SIZE:
        df = df.tail(LIVE_BUFFER_SIZE)
    df.to_csv(path, index=False)
    log(f"weekly buffer {symbol}/{timeframe} length now {len(df)}")
    return len(df)

def load_weekly_df(symbol, timeframe):
    path = weekly_buffer_path(symbol, timeframe)
    if os.path.exists(path):
        try:
            df = pd.read_csv(path, parse_dates=['time'])
            df.sort_values('time', inplace=True)
            return df
        except Exception:
            return pd.DataFrame()
    return pd.DataFrame()

# ----------------- Historical ingestion -----------------
def ingest_weekly_to_historical(symbol, timeframe):
    wk = weekly_buffer_path(symbol, timeframe)
    if not os.path.exists(wk):
        return 0
    try:
        dfw = pd.read_csv(wk, parse_dates=['time'])
        master_path = os.path.join(DATA_FOLDER, f"{symbol}_{timeframe}.csv")
        if os.path.exists(master_path):
            dm = pd.read_csv(master_path, parse_dates=['time'])
            dfm = pd.concat([dm, dfw], ignore_index=True)
        else:
            dfm = dfw
        dfm.drop_duplicates(subset=['time','open','high','low','close'], inplace=True)
        dfm.sort_values('time', inplace=True)
        dfm.to_csv(master_path, index=False)
        os.remove(wk)
        log(f"Ingested weekly {wk} -> {master_path} (rows now {len(dfm)})")
        return len(dfw)
    except Exception as e:
        log(f"Ingest failed: {e}")
        return 0

def load_master_df_all():
    files = [f for f in os.listdir(DATA_FOLDER) if f.endswith('.csv')]
    dfs = []
    for f in files:
        try:
            path = os.path.join(DATA_FOLDER, f)
            df = pd.read_csv(path, parse_dates=['time'])
            cols = [c.lower() for c in df.columns]
            if 'time' in cols and 'open' in cols:
                df = df[['time','open','high','low','close','volume']].copy()
                # Infer timeframe from filename (right-most underscore token)
                name, _ = os.path.splitext(f)
                if '_' in name:
                    parts = name.rsplit('_', 1)
                    tf_candidate = parts[1]
                else:
                    tf_candidate = 'unknown'
                # Normalize timeframe string (upper)
                timeframe = str(tf_candidate).upper()
                df['timeframe'] = timeframe
                dfs.append(df)
        except Exception as e:
            log(f"load_master_df_all skip {f}: {e}")
    if not dfs:
        return pd.DataFrame()
    master = pd.concat(dfs, ignore_index=True)
    master.drop_duplicates(subset=['time','open','high','low','close'], inplace=True)
    master.sort_values(['time','timeframe'], inplace=True)
    return master

# ----------------- Features & training -----------------
def feature_engineer(df):
    """
    Engineer features for model training.
    Handles short buffers gracefully with proper padding.
    """
    df = df.copy()
    df['return'] = df['close'].pct_change().fillna(0)
    
    # Use min_periods to avoid NaN for short windows
    # This ensures we get valid MA values even with few bars
    df['ma_5'] = df['close'].rolling(5, min_periods=1).mean()
    df['ma_20'] = df['close'].rolling(20, min_periods=min(len(df), 20)).mean()
    
    # Ensure no NaN values slip through
    df['ma_5'].fillna(df['close'], inplace=True)
    df['ma_20'].fillna(df['close'], inplace=True)
    
    return df

def train_models():
    if not RETRAIN_LOCK.acquire(blocking=False):
        log("Retrain already running; skipping.")
        return {"status":"locked"}
    try:
        log("Retrain started.")
        master = load_master_df_all()
        if master.empty or len(master) < MIN_ROWS_FOR_RETRAIN:
            log(f"Insufficient data for retrain (rows={len(master)}).")
            return {"status":"insufficient", "rows": len(master)}

        # Optionally perform incremental retrain using metadata last_retrain timestamp
        if INCREMENTAL_RETRAIN and os.path.exists(METADATA_FILE):
            try:
                with open(METADATA_FILE, 'r') as mf:
                    meta = json.load(mf)
                last_retrain = meta.get('last_retrain')
                if last_retrain:
                    try:
                        last_dt = datetime.strptime(last_retrain, "%Y-%m-%d %H:%M:%S")
                        master = master[master['time'] >= last_dt]
                        log(f"Performing incremental retrain on rows since {last_retrain} (rows={len(master)})")
                    except Exception:
                        log("Could not parse last_retrain in metadata; full retrain will proceed.")
            except Exception:
                pass

        df = feature_engineer(master)
        # Compute target within each timeframe to avoid look-ahead across different TF files
        try:
            df = df.sort_values(['time','timeframe'])
            df['target'] = df.groupby('timeframe')['close'].shift(-1) > df['close']
            df['target'] = df['target'].astype(int)
        except Exception:
            # Fallback: compute global next-close target (legacy behavior)
            df['target'] = (df['close'].shift(-1) > df['close']).astype(int)
        df.dropna(inplace=True)
        now = datetime.utcnow()
        results = {}

        # horizons definition (keep existing ensemble horizons but evaluate metrics)
        horizons = {'short':365, 'mid':365*5, 'long':365*25}
        for horizon, days in horizons.items():
            if horizon == 'long':
                df_h = df.copy()
            else:
                cutoff = datetime.utcnow() - timedelta(days=days)
                df_h = df[df['time'] >= cutoff]
            if df_h.empty:
                results[horizon] = {'status':'no_data'}
                continue
            X = df_h[['open','high','low','close','ma_5','ma_20','return']].values
            y = df_h['target'].values
            # simple time-based holdout: last 5% rows (min 100) as validation
            val_size = max(100, int(0.05 * len(X)))
            if val_size >= len(X):
                X_train, y_train = X, y
                X_val, y_val = None, None
            else:
                X_train, X_val = X[:-val_size], X[-val_size:]
                y_train, y_val = y[:-val_size], y[-val_size:]

            scaler = StandardScaler()
            Xs_train = scaler.fit_transform(X_train)
            model = RandomForestClassifier(n_estimators=200, random_state=42, n_jobs=-1)
            model.fit(Xs_train, y_train)

            # evaluate on holdout if available
            metrics = {}
            if X_val is not None and len(X_val) > 0:
                try:
                    Xs_val = scaler.transform(X_val)
                    preds = model.predict(Xs_val)
                    probs = model.predict_proba(Xs_val)[:, 1]
                    acc = float(accuracy_score(y_val, preds))
                    metrics['accuracy'] = acc
                    try:
                        auc = float(roc_auc_score(y_val, probs))
                        metrics['roc_auc'] = auc
                    except Exception:
                        metrics['roc_auc'] = None
                except Exception as e:
                    log(f"Evaluation failed for horizon {horizon}: {e}")

            # atomic save
            tmp_model = MODEL_FILES_ENSEMBLE[horizon] + '.tmp'
            tmp_scaler = SCALER_FILES_ENSEMBLE[horizon] + '.tmp'
            dump(model, tmp_model)
            dump(scaler, tmp_scaler)
            # backup previous
            if os.path.exists(MODEL_FILES_ENSEMBLE[horizon]):
                bak = os.path.join(BACKUP_FOLDER, f"{horizon}_{now.strftime('%Y%m%d_%H%M%S')}.pkl")
                shutil.copy2(MODEL_FILES_ENSEMBLE[horizon], bak)
            os.replace(tmp_model, MODEL_FILES_ENSEMBLE[horizon])
            os.replace(tmp_scaler, SCALER_FILES_ENSEMBLE[horizon])
            results[horizon] = {'rows': len(df_h), 'metrics': metrics}
            log(f"Trained {horizon} with {len(df_h)} rows. metrics={metrics}")
        # write metadata (include per-horizon results/metrics)
        meta = {"last_retrain": now.strftime("%Y-%m-%d %H:%M:%S"), "rows_total": len(df), "results": results}
        try:
            with open(METADATA_FILE, "w") as f:
                json.dump(meta, f, indent=2)
        except Exception as e:
            log("Failed writing metadata: " + str(e))
        # reload models
        load_models_if_needed(force=True)
        log("Retrain finished.")
        # append retrain log with metrics
        try:
            with open(RETRAIN_LOG, "a") as f:
                f.write(f"{datetime.utcnow().isoformat()} - retrain complete - rows={len(df)} - results={json.dumps(results)}\n")
        except Exception as e:
            log(f"Failed to write retrain log: {e}")
        log("Retrain finished.")
        return {"status":"success", "results": results}
    except Exception as e:
        log("Retrain error: " + str(e))
        return {"status":"error", "error": str(e)}
    finally:
        try:
            RETRAIN_LOCK.release()
        except RuntimeError as e:
            log(f"Lock release error in train_models: {e}")

# ----------------- Model loading (with fallback) -----------------
def load_models_if_needed(force=False):
    global _loaded, _scalers, _last_loaded_time
    with MODEL_ACCESS_LOCK:
        if not force and time.time() - _last_loaded_time < 10:
            return
        
        # Try ensemble first: ALL three models (short, mid, long) must exist
        log("Checking for ensemble models...")
        ensemble_available = all(
            os.path.exists(MODEL_FILES_ENSEMBLE[h]) and os.path.exists(SCALER_FILES_ENSEMBLE[h])
            for h in ["short", "mid", "long"]
        )
        
        if ensemble_available:
            log("Ensemble models found. Loading all three horizons...")
            for h in ['short','mid','long']:
                try:
                    model_path = MODEL_FILES_ENSEMBLE[h]
                    scaler_path = SCALER_FILES_ENSEMBLE[h]
                    _loaded[h] = load(model_path)
                    _scalers[h] = load(scaler_path)
                    log(f"Loaded ensemble model {h} from {model_path}")
                except Exception as e:
                    _loaded[h] = None
                    _scalers[h] = None
                    log(f"ERROR: Failed loading ensemble {h}: {e}")
            _loaded['single'] = None
            _scalers['single'] = None
        else:
            log("Ensemble models NOT complete. Checking for single-model fallback...")
            # Try single-model fallback only if ensemble unavailable
            if os.path.exists(SINGLE_MODEL) and os.path.exists(SINGLE_SCALER):
                log(f"Single model found: {SINGLE_MODEL}")
                try:
                    _loaded['single'] = load(SINGLE_MODEL)
                    _scalers['single'] = load(SINGLE_SCALER)
                    # Null ensemble entries
                    for h in ['short','mid','long']:
                        _loaded[h] = None
                        _scalers[h] = None
                    log("Loaded single fallback model (eurusd_model.pkl)")
                except Exception as e:
                    log(f"ERROR: Failed loading single model: {e}")
                    for h in ['short','mid','long','single']:
                        _loaded[h] = None
                        _scalers[h] = None
            else:
                log("No models found (neither ensemble nor single). Waiting for training...")
                for h in ['short','mid','long','single']:
                    _loaded[h] = None
                    _scalers[h] = None

        _last_loaded_time = time.time()
        # print metadata if present
        if os.path.exists(METADATA_FILE):
            try:
                with open(METADATA_FILE, "r") as f:
                    meta = json.load(f)
                log(f"Metadata loaded. last_retrain={meta.get('last_retrain')} rows_total={meta.get('rows_total')}")
            except Exception as e:
                log("Failed to read metadata: " + str(e))

# ----------------- Prediction helper -----------------
def predict_from_models(X_row):
    """
    X_row: single-row array shape (1, features)
    returns final_prob (0..1), breakdown dict
    Thread-safe: acquires MODEL_ACCESS_LOCK for model/scaler access.
    """
    load_models_if_needed()
    with MODEL_ACCESS_LOCK:
        # If single model loaded, use it
        if _loaded.get('single') is not None and _scalers.get('single') is not None:
            try:
                Xs = _scalers['single'].transform(X_row)
                p = float(_loaded['single'].predict_proba(Xs)[0,1])
                return p, {"single": p}
            except Exception as e:
                log("Single model predict failed: " + str(e))
                return None, {}
        # else ensemble
        probs = {}
        for h in ['short','mid','long']:
            model = _loaded.get(h)
            scaler = _scalers.get(h)
            if model is None or scaler is None:
                probs[h] = None
                continue
            try:
                Xs = scaler.transform(X_row)
                p = float(model.predict_proba(Xs)[0,1])
                probs[h] = p
            except Exception as e:
                log(f"prediction error for {h}: {e}")
                probs[h] = None
        weighted = 0.0
        total_w = 0.0
        breakdown = {}
        for h,w in ENSEMBLE_WEIGHTS.items():
            p = probs.get(h)
            if p is None: continue
            weighted += p * w
            total_w += w
            breakdown[h] = p
        if total_w == 0:
            return None, {}
        final_prob = weighted / total_w
        return final_prob, breakdown

# ----------------- Endpoints -----------------
@app.route("/status", methods=["GET"])
def status():
    load_models_if_needed()
    models_present = {k: (_loaded.get(k) is not None) for k in ['short','mid','long','single']}
    meta = {}
    if os.path.exists(METADATA_FILE):
        try:
            with open(METADATA_FILE,'r') as f:
                meta = json.load(f)
        except Exception as e:
            log(f"Failed to read metadata in status: {e}")
            meta = {}
    try:
        live_buffers = os.listdir(WEEKLY_FOLDER)
    except Exception as e:
        log(f"Failed to list weekly folder in status: {e}")
        live_buffers = []
    return jsonify({"status":"ok", "live_buffers": live_buffers, "models": models_present, "metadata": meta})

@app.route("/ingest", methods=["POST"])
def ingest():
    try:
        data = request.get_json(force=True, silent=True)
        if not data:
            return jsonify({"error":"No JSON body"}), 400
        symbol = data.get('Symbol') or data.get('symbol')
        timeframe = data.get('Timeframe') or data.get('timeframe')
        bars = data.get('Bars') or data.get('bars') or []
        if not symbol or not timeframe or not bars:
            return jsonify({"error":"Missing fields"}), 400
        count = append_to_weekly(symbol, timeframe, bars)
        return jsonify({"status":"ok","ingested": count}), 200
    except Exception as e:
        log("ingest error: " + str(e))
        return jsonify({"error": str(e)}), 500

@app.route("/predict", methods=["POST"])
def predict_endpoint():
    try:
        data = request.get_json(force=True, silent=True)
        if not data:
            raw = request.get_data(as_text=True)
            if raw:
                data = json.loads(raw)
        if not data:
            return jsonify({"error":"No JSON"}), 400
        lower = {k.lower(): v for k, v in data.items()}
        symbol = lower.get('symbol','EURUSD')
        timeframe = lower.get('timeframe','H1')
        try:
            open_ = float(lower.get('open', 0))
            high  = float(lower.get('high', 0))
            low   = float(lower.get('low', 0))
            close = float(lower.get('close', 0))
            vol   = int(lower.get('volume', 0))
        except:
            return jsonify({"error":"Invalid numeric fields"}), 400
        # Accept 't' from EA (must be UTC seconds since epoch)
        # EA should convert broker time to UTC before sending
        # Fallback to current UTC time if not provided
        t = int(lower.get('t', time.time()))
        # IMPORTANT: All timestamps in the system must be UTC for consistency
        log(f"Received candle for {symbol}/{timeframe} at UTC timestamp {t}")
        row = [{'t': t, 'o': open_, 'h': high, 'l': low, 'c': close, 'v': vol}]
        append_to_weekly(symbol, timeframe, row)
        df_live = load_weekly_df(symbol, timeframe)
        if df_live.empty:
            # Use conservative defaults for empty buffer
            ma_5 = close
            ma_20 = close
            ret = 0.0
        else:
            df_f = df_live.copy()
            df_f['return'] = df_f['close'].pct_change().fillna(0)
            df_f['ma_5'] = df_f['close'].rolling(5, min_periods=1).mean()
            df_f['ma_20'] = df_f['close'].rolling(20, min_periods=1).mean()
            last = df_f.iloc[-1]
            ma_5 = float(last['ma_5'])
            ma_20 = float(last['ma_20'])
            ret = float(last['return'])
        X_row = np.array([[open_, high, low, close, ma_5, ma_20, ret]], dtype=float)
        prob, breakdown = predict_from_models(X_row)
        if prob is None:
            return jsonify({
                "ok": False,
                "error": "model_not_trained",
                "message": "No models available. Server may not be trained yet.",
                "error_code": "MODEL_NOT_AVAILABLE"
            }), 503
        # simple boost heuristic
        boost = 0.0
        try:
            if not df_live.empty and len(df_live) >= 3:
                closes = df_live['close'].astype(float).values[-3:]
                if closes[2] > closes[1] > closes[0]:
                    boost += 0.02
                if closes[2] < closes[1] < closes[0]:
                    boost -= 0.02
        except Exception:
            pass
        final_prob = min(max(prob + boost, 0.0), 1.0)
        if final_prob >= 0.55:
            signal = "BUY"
        elif final_prob <= 0.45:
            signal = "SELL"
        else:
            signal = "HOLD"
        response = {
            "signal": signal,
            "prob": round(final_prob,4),
            "breakdown": breakdown,
            "STOP_LOSS_PIPS": 30,
            "TAKE_PROFIT_PIPS": 60
        }
        return jsonify(response), 200
    except Exception as e:
        log("predict error: " + str(e))
        return jsonify({"error": str(e)}), 500

@app.route("/train", methods=["POST"])
def train_endpoint():
    try:
        data = request.get_json(force=True, silent=True)
        if not data:
            raw = request.get_data(as_text=True)
            if raw:
                data = json.loads(raw)
        if not data:
            return jsonify({"error":"No JSON"}), 400
        symbol = data.get('Symbol') or data.get('symbol')
        timeframe = data.get('Timeframe') or data.get('timeframe')
        bars = data.get('Bars') or data.get('bars') or []
        if not symbol or not timeframe or not bars:
            return jsonify({"error":"Missing fields"}), 400
        append_to_weekly(symbol, timeframe, bars)
        ingested_rows = ingest_weekly_to_historical(symbol, timeframe)
        # trigger background retrain
        t = threading.Thread(target=train_models, daemon=True)
        t.start()
        return jsonify({"status":"accepted","ingested_rows":ingested_rows}), 200
    except Exception as e:
        log("train endpoint error: " + str(e))
        return jsonify({"error": str(e)}), 500
# ---------- Scheduler & safe background retrain (REPLACEMENT) ----------
# NOTE: This block replaces the duplicated imports and the older broken scheduler.
# It uses the RETRAIN_LOCK defined earlier and the existing helpers train_models / ingest_weekly_to_historical.

RETRAIN_WEEKDAY = 4     # Friday (Mon=0)
RETRAIN_HOUR    = 21
RETRAIN_MINUTE  = 59

# Use the same lock defined earlier
# RETRAIN_LOCK is already defined at top; reuse it.
last_auto_retrain = None   # stored in memory; can persist to metadata if desired

def auto_weekly_retrain_scheduler():
    global last_auto_retrain
    log("[Scheduler] Weekly retrain scheduler started.")
    while True:
        try:
            now = datetime.utcnow()
            # Time match
            if (now.weekday() == RETRAIN_WEEKDAY and
                now.hour == RETRAIN_HOUR and
                now.minute == RETRAIN_MINUTE):
                # Avoid duplicates in same minute
                if last_auto_retrain is None or (now - last_auto_retrain).total_seconds() > 120:
                    last_auto_retrain = now
                    log("[Scheduler] Weekly retrain window reached. Scheduling retrain.")
                    safe_background_retrain()
            time.sleep(30)
        except Exception as e:
            log(f"[Scheduler] ERROR: {e}")
            import traceback
            traceback.print_exc()
            time.sleep(60)

def safe_background_retrain():
    """Thread-safe wrapper that ingests weekly buffers and triggers train_models().
    Note: Does NOT acquire lock. train_models() handles its own locking to prevent concurrent retrains.
    """
    def _worker():
        try:
            log("[AutoRetrain] Starting auto retrain worker.")
            # 1. Find weekly files in WEEKLY_FOLDER
            weekly_files = [os.path.join(WEEKLY_FOLDER, f) for f in os.listdir(WEEKLY_FOLDER) if f.endswith('.csv')]
            if not weekly_files:
                log("[AutoRetrain] No weekly buffers found. Releasing lock.")
                return

            # 2. For each weekly file, try to infer symbol/timeframe from filename and ingest
            total_ingested = 0
            for wf in weekly_files:
                # Expected filename format: SYMBOL_TIMEFRAME.csv
                # Examples: EURUSD_H1.csv, XAU_USD_H1.csv, GBPUSD_M30.csv
                # Strategy: rsplit on LAST underscore to separate symbol from timeframe
                base = os.path.basename(wf)
                name, _ = os.path.splitext(base)
                if '_' in name:
                    # Split on LAST underscore: timeframe is usually 1-3 chars (H1, H4, M30, M5, etc)
                    parts = name.rsplit('_', 1)  # Right split: splits on rightmost underscore
                    if len(parts) == 2 and len(parts[1]) <= 3:  # timeframe check
                        symbol, timeframe = parts
                    else:
                        # Fallback: still assume last part is timeframe (robust parsing)
                        symbol, timeframe = name.rsplit('_', 1)
                else:
                    # No underscore: treat whole name as symbol
                    symbol, timeframe = name, "unknown"
                try:
                    # ingest_weekly_to_historical removes the weekly file on success
                    rows = ingest_weekly_to_historical(symbol, timeframe)
                    total_ingested += rows
                except Exception as e:
                    log(f"[AutoRetrain] Failed ingest {wf}: {e}")

            log(f"[AutoRetrain] Ingested rows from weekly: {total_ingested}")

            # 3. Trigger retrain in background (train_models handles locking and reload)
            # spawn as a thread so the scheduler loop isn't blocked by model training
            t = threading.Thread(target=train_models, daemon=True)
            t.start()
            log("[AutoRetrain] train_models started in background thread.")

            # 4. Append to retrain log file (use existing RETRAIN_LOG)
            try:
                with open(RETRAIN_LOG, "a") as lf:
                    lf.write(f"{datetime.utcnow().isoformat()} - auto_retrain started - ingested_rows={total_ingested}\n")
            except Exception:
                pass

        except Exception as e:
            try:
                with open(RETRAIN_LOG, "a") as lf:
                    lf.write(f"{datetime.utcnow().isoformat()} - auto_retrain FAILED: {e}\n")
            except Exception as log_e:
                log(f"Failed to write retrain error log: {log_e}")
            log(f"[AutoRetrain] ERROR: {e}")

    threading.Thread(target=_worker, daemon=True).start()

# ----------------- start-up -----------------
if __name__ == "__main__":
    # attempt to create minimal metadata if missing
    if not os.path.exists(METADATA_FILE):
        try:
            with open(METADATA_FILE,"w") as f:
                json.dump({"last_retrain": None, "rows_total": None}, f)
        except Exception as e:
            log(f"Failed to create metadata file: {e}")
    # attempt load models (prints metadata if present)
    load_models_if_needed(force=True)
    # Launch scheduler thread
    threading.Thread(target=auto_weekly_retrain_scheduler, daemon=True).start()
    log("[Main] Scheduler thread launched.")
    host = "0.0.0.0"
    port = 5000
    log(f"AI server starting on {host}:{port}. LIVE_BUFFER_SIZE={LIVE_BUFFER_SIZE}")
    
    app.run(host=host, port=port)
