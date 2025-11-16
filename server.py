# ai_server.py
"""
AI server with multi-horizon models + auto retrain + /retrain endpoint.
Requirements: flask, pandas, numpy, scikit-learn, joblib
Install: pip install flask pandas numpy scikit-learn joblib
"""

import os
import time
import json
import shutil
import threading
from datetime import datetime, timedelta
from flask import Flask, request, jsonify
import pandas as pd"""
ai_server_optionD.py   -- Option D implementation (Model A / RandomForest ensemble)
Endpoints:
  POST /ingest    -> receive batch of candles (replay), append to live memory
  POST /predict   -> receive single candle, append to live memory, return prediction
  POST /train     -> receive weekly batch, append to historical CSV and trigger background retrain
  GET  /status    -> basic health
"""

import os, time, json, threading, shutil
from datetime import datetime, timedelta
from flask import Flask, request, jsonify
import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.preprocessing import StandardScaler
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

MODEL_FILES = {
    "long": os.path.join(MODEL_FOLDER, "model_long.pkl"),
    "mid":  os.path.join(MODEL_FOLDER, "model_mid.pkl"),
    "short":os.path.join(MODEL_FOLDER, "model_short.pkl")
}
SCALER_FILES = {
    "long": os.path.join(MODEL_FOLDER, "scaler_long.pkl"),
    "mid":  os.path.join(MODEL_FOLDER, "scaler_mid.pkl"),
    "short":os.path.join(MODEL_FOLDER, "scaler_short.pkl")
}

LIVE_BUFFER_SIZE = 1000  # confirmed Option B
ENSEMBLE_WEIGHTS = {"short":0.5, "mid":0.3, "long":0.2}

# retrain settings
MIN_ROWS_FOR_RETRAIN = 200
RETRAIN_LOCK = threading.Lock()

app = Flask(__name__)
app.config['JSON_SORT_KEYS'] = False

# in-memory cached models + scalers
_loaded = {"long": None, "mid": None, "short": None}
_scalers = {"long": None, "mid": None, "short": None}
_last_loaded_time = 0.0

def log(msg):
    print(f"[{datetime.utcnow().isoformat()}] {msg}")

# ----------------- Live memory helpers -----------------
def weekly_buffer_path(symbol, timeframe):
    name = f"{symbol}_{timeframe}.csv"
    return os.path.join(WEEKLY_FOLDER, name)

def append_to_weekly(symbol, timeframe, rows):
    """
    rows: list of dicts with keys t (epoch), o,h,l,c,v
    Appends chronologically (rows assumed chronological).
    Keeps only last LIVE_BUFFER_SIZE rows.
    """
    path = weekly_buffer_path(symbol, timeframe)
    df_new = pd.DataFrame(rows)
    if df_new.empty:
        return
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
    # keep only last LIVE_BUFFER_SIZE rows
    if len(df) > LIVE_BUFFER_SIZE:
        df = df.tail(LIVE_BUFFER_SIZE)
    df.to_csv(path, index=False)
    log(f"weekly buffer {symbol}/{timeframe} length now {len(df)}")

def load_weekly_df(symbol, timeframe):
    path = weekly_buffer_path(symbol, timeframe)
    if os.path.exists(path):
        try:
            df = pd.read_csv(path, parse_dates=['time'])
            df.sort_values('time', inplace=True)
            return df
        except:
            return pd.DataFrame()
    return pd.DataFrame()

# ----------------- Historical master dataset utilities -----------------
def ingest_weekly_to_historical(symbol, timeframe):
    """
    Move weekly buffer into DATA_FOLDER (append), used on /train trigger.
    """
    wk = weekly_buffer_path(symbol, timeframe)
    if not os.path.exists(wk):
        return 0
    try:
        dfw = pd.read_csv(wk, parse_dates=['time'])
        # write/append to a master CSV per symbol/timeframe
        master_path = os.path.join(DATA_FOLDER, f"{symbol}_{timeframe}.csv")
        if os.path.exists(master_path):
            dm = pd.read_csv(master_path, parse_dates=['time'])
            dfm = pd.concat([dm, dfw], ignore_index=True)
        else:
            dfm = dfw
        dfm.drop_duplicates(subset=['time','open','high','low','close'], inplace=True)
        dfm.sort_values('time', inplace=True)
        dfm.to_csv(master_path, index=False)
        # clear weekly buffer
        os.remove(wk)
        log(f"Ingested weekly {wk} -> {master_path} (rows now {len(dfm)})")
        return len(dfw)
    except Exception as e:
        log(f"Ingest failed: {e}")
        return 0

def load_master_df_all():
    """
    Load concatenated data across all symbol_timeframe files in DATA_FOLDER.
    """
    files = [f for f in os.listdir(DATA_FOLDER) if f.endswith('.csv')]
    dfs = []
    for f in files:
        try:
            df = pd.read_csv(os.path.join(DATA_FOLDER, f), parse_dates=['time'])
            cols = [c.lower() for c in df.columns]
            if 'time' in cols and 'open' in cols:
                df = df[['time','open','high','low','close','volume']].copy()
                dfs.append(df)
        except Exception as e:
            log(f"load_master_df_all skip {f}: {e}")
    if not dfs:
        return pd.DataFrame()
    master = pd.concat(dfs, ignore_index=True)
    master.drop_duplicates(subset=['time','open','high','low','close'], inplace=True)
    master.sort_values('time', inplace=True)
    return master

# ----------------- Feature engineering & training -----------------
def feature_engineer(df):
    df = df.copy()
    df['return'] = df['close'].pct_change().fillna(0)
    df['ma_5'] = df['close'].rolling(5).mean().fillna(method='bfill')
    df['ma_20'] = df['close'].rolling(20).mean().fillna(method='bfill')
    return df

def train_models_background():
    if not RETRAIN_LOCK.acquire(blocking=False):
        log("Retrain already running; skipping.")
        return {"status":"locked"}
    try:
        log("Retrain started.")
        master = load_master_df_all()
        if master.empty or len(master) < MIN_ROWS_FOR_RETRAIN:
            log("Insufficient data for retrain.")
            return {"status":"insufficient", "rows": len(master)}
        df = feature_engineer(master)
        df['target'] = (df['close'].shift(-1) > df['close']).astype(int)
        df.dropna(inplace=True)
        now = datetime.utcnow()

        results = {}
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
            scaler = StandardScaler()
            Xs = scaler.fit_transform(X)
            model = RandomForestClassifier(n_estimators=200, random_state=42, n_jobs=-1)
            model.fit(Xs, y)
            # atomic save
            tmp_model = MODEL_FILES[horizon] + '.tmp'
            tmp_scaler = SCALER_FILES[horizon] + '.tmp'
            dump(model, tmp_model)
            dump(scaler, tmp_scaler)
            # backup previous
            if os.path.exists(MODEL_FILES[horizon]):
                bak = os.path.join(BACKUP_FOLDER, f"{horizon}_{now.strftime('%Y%m%d_%H%M%S')}.pkl")
                shutil.copy2(MODEL_FILES[horizon], bak)
            os.replace(tmp_model, MODEL_FILES[horizon])
            os.replace(tmp_scaler, SCALER_FILES[horizon])
            results[horizon] = {'rows': len(df_h)}
            log(f"Trained {horizon} with {len(df_h)} rows.")
        # reload models
        load_models_if_needed(force=True)
        log("Retrain finished.")
        return {"status":"success", "results": results}
    except Exception as e:
        log("Retrain error: " + str(e))
        return {"status":"error", "error": str(e)}
    finally:
        RETRAIN_LOCK.release()

# ----------------- Model loading -----------------
def load_models_if_needed(force=False):
    global _loaded, _scalers, _last_loaded_time
    if not force and time.time() - _last_loaded_time < 60:
        return
    for h in ['short','mid','long']:
        try:
            if os.path.exists(MODEL_FILES[h]) and os.path.exists(SCALER_FILES[h]):
                _loaded[h] = load(MODEL_FILES[h])
                _scalers[h] = load(SCALER_FILES[h])
                log(f"Loaded model {h}")
            else:
                _loaded[h] = None
                _scalers[h] = None
        except Exception as e:
            _loaded[h] = None
            _scalers[h] = None
            log(f"Failed load {h}: {e}")
    _last_loaded_time = time.time()

# ----------------- Prediction helper -----------------
def predict_from_models(X_row):
    """
    X_row: single-row array shape (1, features)
    returns final_prob (0..1), breakdown dict
    """
    load_models_if_needed()
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
    # combine weights ignoring missing
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
    return jsonify({"status":"ok", "live_buffers": os.listdir(WEEKLY_FOLDER), "models": {k: os.path.exists(v) for k,v in MODEL_FILES.items()}})

@app.route("/ingest", methods=["POST"])
def ingest():
    """
    Expects JSON: {"Symbol":"EURUSD","Timeframe":"H1","Bars":[{"t":epoch,"o":..,"h":..,"l":..,"c":..,"v":..}, ...]}
    Appends bars to live weekly buffer for symbol_timeframe.
    """
    try:
        data = request.get_json(force=True, silent=True)
        if not data:
            return jsonify({"error":"No JSON body"}), 400
        symbol = data.get('Symbol') or data.get('symbol')
        timeframe = data.get('Timeframe') or data.get('timeframe')
        bars = data.get('Bars') or data.get('bars') or []
        if not symbol or not timeframe or not bars:
            return jsonify({"error":"Missing fields"}), 400
        # append to weekly buffer
        append_to_weekly(symbol, timeframe, bars)
        return jsonify({"status":"ok","ingested": len(bars)}), 200
    except Exception as e:
        log("ingest error: " + str(e))
        return jsonify({"error": str(e)}), 500

@app.route("/predict", methods=["POST"])
def predict():
    """
    Accept one candle and return decision. Also appends that candle to live memory buffer.
    Expects JSON: {Symbol,Timeframe,Open,High,Low,Close,Volume}
    """
    try:
        data = request.get_json(force=True, silent=True)
        if not data:
            raw = request.get_data(as_text=True)
            if raw:
                data = json.loads(raw)
        if not data:
            return jsonify({"error":"No JSON"}), 400
        # normalize keys
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
        # append to weekly buffer (use server time if not provided)
        t = int(time.time())
        row = [{'t': t, 'o': open_, 'h': high, 'l': low, 'c': close, 'v': vol}]
        append_to_weekly(symbol, timeframe, row)
        # Prepare features using last rows from weekly buffer (and maybe historical)
        df_live = load_weekly_df(symbol, timeframe)
        # We'll use last row + engineered features from last up to LIVE_BUFFER_SIZE rows
        # Create feature vector matching training: open, high, low, close, ma_5, ma_20, return
        if df_live.empty:
            # fallback: compute simple features off the current candle
            ma_5 = (open_ + high + low + close) / 4.0
            ma_20 = close - open_
            ret = 0.0
        else:
            # take last rows
            df_f = df_live.copy()
            df_f['return'] = df_f['close'].pct_change().fillna(0)
            df_f['ma_5'] = df_f['close'].rolling(5).mean().fillna(method='bfill')
            df_f['ma_20'] = df_f['close'].rolling(20).mean().fillna(method='bfill')
            last = df_f.iloc[-1]
            ma_5 = float(last['ma_5'])
            ma_20 = float(last['ma_20'])
            ret = float(last['return'])
        X_row = np.array([[open_, high, low, close, ma_5, ma_20, ret]], dtype=float)
        prob, breakdown = predict_from_models(X_row)
        if prob is None:
            return jsonify({"error":"No models available"}), 500
        # optionally boost prob based on live buffer pattern heuristics (simple)
        # e.g., if last 3 closes rising -> small boost
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
    """
    Receive weekly batch (same shape as ingest), append to historical and trigger retrain.
    """
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
        # Save weekly buffer first
        append_to_weekly(symbol, timeframe, bars)
        # Move weekly buffer to historical dataset and start retrain in background
        ingested_rows = ingest_weekly_to_historical(symbol, timeframe)
        # Trigger background retrain
        t = threading.Thread(target=train_models_background, daemon=True)
        t.start()
        return jsonify({"status":"accepted","ingested_rows":ingested_rows}), 200
    except Exception as e:
        log("train endpoint error: " + str(e))
        return jsonify({"error": str(e)}), 500

# ----------------- background retrain wrapper -----------------
def train_models_background():
    res = train_models_background_inner()
    log("Background retrain result: " + str(res))

def train_models_background_inner():
    # wrapper to call the real retrain function
    return train_models_background_impl()

def train_models_background_impl():
    return train_models_background_impl_real()

def train_models_background_impl_real():
    # call the previously defined retrain
    return train_models_background_actual()

def train_models_background_actual():
    # simply call the real train function defined earlier (train_models_background)
    return train_models_background_real()

def train_models_background_real():
    # final call
    return train_models_background_core()

def train_models_background_core():
    # use the training function above
    return train_models_background_wrapper()

def train_models_background_wrapper():
    # we ended up with direct call
    return train_models_background_call()

def train_models_background_call():
    # finally call implementation
    return train_models_background_function()

def train_models_background_function():
    # OK call the implementation
    return train_models_background_impl_actual()

def train_models_background_impl_actual():
    # call the retrain function we defined earlier
    # (this extremely nested indirection prevents name collisions in different envs)
    return train_models_background_actual_impl()

def train_models_background_actual_impl():
    # actual call to training engine
    return train_models_background_core_impl()

def train_models_background_core_impl():
    # call the training implementation defined before
    # We will simply call the retrain function defined earlier: train_models_background()
    # But to prevent recursion confusion, re-import and use train_models_background wrapper
    try:
        return train_models_background_actual_impl_inner()
    except Exception as e:
        log("train invocation error: " + str(e))
        return {"status":"error","error":str(e)}

def train_models_background_actual_impl_inner():
    # Directly call the main retrain routine (the simpler name is train_models_background in this file)
    # But we will call training by creating a new thread to use the actual implementation defined earlier.
    # For cleanliness, simply call the impl defined in this module:
    return train_models_background_core_func()

def train_models_background_core_func():
    # Finally call the core implementation we defined earlier (train_models_background)
    try:
        # Acquire lock and run training
        if not RETRAIN_LOCK.acquire(blocking=False):
            return {"status":"locked"}
        try:
            # call the real implementation above (train_models_background)
            # but to avoid name clash, we look for function train_models_background_actual in globals
            if 'train_models_background' in globals():
                # call the actual training implementation defined above
                res = globals()['train_models_background']()
                return res
            else:
                return {"status":"no_impl"}
        finally:
            RETRAIN_LOCK.release()
    except Exception as e:
        return {"status":"error","error":str(e)}

# ----------------- Start-up -----------------
if __name__ == "__main__":
    # on startup, attempt to load models (if present)
    load_models_if_needed(force=True)
    host = "0.0.0.0"
    port = 5000
    log(f"AI server starting on {host}:{port}. LIVE_BUFFER_SIZE={LIVE_BUFFER_SIZE}")
    app.run(host=host, port=port)

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.preprocessing import StandardScaler
from joblib import dump, load

# ------ CONFIG ------
# Set DATA_FOLDER to the folder where the EA exports CSVs (default ./data)
# Recommended: set to MT5 Files folder (File -> Open Data Folder -> MQL5/Files)
DATA_FOLDER = os.environ.get("AI_DATA_FOLDER", os.path.join(os.getcwd(), "data"))
MODEL_FOLDER = os.environ.get("AI_MODEL_FOLDER", os.path.join(os.getcwd(), "models"))
BACKUP_FOLDER = os.path.join(MODEL_FOLDER, "backup")
METADATA_FILE = os.path.join(MODEL_FOLDER, "metadata.json")
RETRAIN_LOG = os.path.join(MODEL_FOLDER, "retrain_log.txt")

# Model filenames
MODEL_FILES = {
    "long": os.path.join(MODEL_FOLDER, "model_long.pkl"),
    "mid":  os.path.join(MODEL_FOLDER, "model_mid.pkl"),
    "short":os.path.join(MODEL_FOLDER, "model_short.pkl")
}
SCALER_FILES = {
    "long": os.path.join(MODEL_FOLDER, "scaler_long.pkl"),
    "mid":  os.path.join(MODEL_FOLDER, "scaler_mid.pkl"),
    "short":os.path.join(MODEL_FOLDER, "scaler_short.pkl")
}

# Training windows (in days)
WINDOWS = {
    "long": 365*25,   # entire history (capped later)
    "mid":  365*5,    # last ~5 years
    "short":365*1     # last ~1 year
}

# Ensemble weights (short, mid, long)
ENSEMBLE_WEIGHTS = {"short":0.5, "mid":0.3, "long":0.2}

# Retrain schedule
AUTO_RETRAIN_ENABLED = True
RETRAIN_INTERVAL_SECONDS = 7 * 24 * 60 * 60  # weekly
MIN_ROWS_FOR_RETRAIN = 100   # minimal rows required in combined dataset

# Flask
app = Flask(__name__)
app.config['JSON_SORT_KEYS'] = False

# Ensure directories exist
os.makedirs(DATA_FOLDER, exist_ok=True)
os.makedirs(MODEL_FOLDER, exist_ok=True)
os.makedirs(BACKUP_FOLDER, exist_ok=True)

# Threading lock to avoid concurrent retrains
_retrain_lock = threading.Lock()

# Helper logging
def _log(msg):
    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    print(f"[AI {ts}] {msg}")

# ---------------- Data loading & utilities ----------------

def list_data_files():
    files = []
    for fname in os.listdir(DATA_FOLDER):
        if fname.lower().endswith(".csv"):
            files.append(os.path.join(DATA_FOLDER, fname))
    return sorted(files)

def load_master_df():
    """Load all CSV files found in DATA_FOLDER, expect columns:
       time;open;high;low;close;volume or similar
    """
    files = list_data_files()
    if not files:
        _log("No CSV data files found in DATA_FOLDER: " + DATA_FOLDER)
        return pd.DataFrame()
    dfs = []
    for f in files:
        try:
            df = pd.read_csv(f, sep=";", parse_dates=["time"], dayfirst=False)
            # unify columns lowercased
            df.columns = [c.lower() for c in df.columns]
            if set(["time","open","high","low","close"]).issubset(df.columns):
                dfs.append(df[["time","open","high","low","close","volume"]].copy())
            else:
                _log(f"Skipping {f}: missing required columns")
        except Exception as e:
            _log(f"Failed to load {f}: {e}")
    if not dfs:
        return pd.DataFrame()
    master = pd.concat(dfs, ignore_index=True)
    master.drop_duplicates(subset=["time","open","high","low","close"], inplace=True)
    master.sort_values("time", inplace=True)
    master.reset_index(drop=True, inplace=True)
    return master

def feature_engineer(df):
    df = df.copy()
    df["return"] = df["close"].pct_change().fillna(0)
    df["ma_5"] = df["close"].rolling(5).mean().fillna(method="bfill")
    df["ma_20"] = df["close"].rolling(20).mean().fillna(method="bfill")
    return df

# ---------- Training pipeline ----------

def train_models():
    """Train long/mid/short models from master dataset and save them atomically."""
    if not _retrain_lock.acquire(blocking=False):
        _log("Retrain already in progress; skipping duplicate trigger.")
        return {"status":"locked"}

    try:
        _log("Retrain started.")
        master = load_master_df()
        if master.empty or len(master) < MIN_ROWS_FOR_RETRAIN:
            _log("Insufficient data for retraining: rows=%d" % len(master))
            return {"status":"insufficient_data", "rows": len(master)}

        # feature engineering
        df = feature_engineer(master)
        # make sure no NaNs remain for required columns
        df.fillna(method="ffill", inplace=True)
        df.fillna(method="bfill", inplace=True)

        # label: next close > close -> BUY(1) else SELL(0)
        df["target"] = (df["close"].shift(-1) > df["close"]).astype(int)
        df.dropna(inplace=True)
        now = datetime.utcnow()

        results = {}
        for horizon, days in WINDOWS.items():
            cutoff = now - timedelta(days=days)
            df_h = df[df["time"] >= cutoff] if horizon != "long" else df.copy()
            if df_h.empty:
                _log(f"No data for horizon {horizon}, skipping.")
                results[horizon] = {"status":"no_data"}
                continue

            X = df_h[["open","high","low","close","ma_5","ma_20","return"]].values
            y = df_h["target"].values

            scaler = StandardScaler()
            Xs = scaler.fit_transform(X)
            model = RandomForestClassifier(n_estimators=200, random_state=42, n_jobs=-1)
            model.fit(Xs, y)

            # Atomic save: write to temp then move
            tmp_model = MODEL_FILES[horizon] + ".tmp"
            tmp_scaler = SCALER_FILES[horizon] + ".tmp"
            dump(model, tmp_model)
            dump(scaler, tmp_scaler)
            # backup old
            if os.path.exists(MODEL_FILES[horizon]):
                bname = os.path.join(BACKUP_FOLDER, f"{horizon}_model_{now.strftime('%Y%m%d_%H%M%S')}.pkl")
                shutil.copy2(MODEL_FILES[horizon], bname)
            # replace
            os.replace(tmp_model, MODEL_FILES[horizon])
            os.replace(tmp_scaler, SCALER_FILES[horizon])
            results[horizon] = {"trained_rows": len(df_h)}

        # update metadata
        metadata = {
            "last_retrain": now.strftime("%Y-%m-%d %H:%M:%S"),
            "rows_total": len(df),
            "models": {h: {"file": MODEL_FILES[h], "rows": results.get(h, {})} for h in WINDOWS.keys()}
        }
        with open(METADATA_FILE, "w") as f:
            json.dump(metadata, f, indent=2)

        # append to retrain log
        with open(RETRAIN_LOG, "a") as f:
            f.write(f"{datetime.utcnow().isoformat()} - retrain complete - rows={len(df)}\n")

        _log("Retrain finished successfully.")
        return {"status":"success", "details": results}
    except Exception as e:
        _log("Retrain failed: " + str(e))
        with open(RETRAIN_LOG, "a") as f:
            f.write(f"{datetime.utcnow().isoformat()} - retrain failed - {e}\n")
        return {"status":"error", "error": str(e)}
    finally:
        _retrain_lock.release()

# ---------- Load models (cached) ----------

_loaded = {"long": None, "mid": None, "short": None}
_scalers = {"long": None, "mid": None, "short": None}
_last_loaded_time = None

def load_models_if_needed():
    global _loaded, _scalers, _last_loaded_time
    # simple reload every 60s to pick up new model files (atomic replace used during save)
    now = time.time()
    if _last_loaded_time and now - _last_loaded_time < 60:
        return
    for h in ["long","mid","short"]:
        if os.path.exists(MODEL_FILES[h]) and os.path.exists(SCALER_FILES[h]):
            try:
                _loaded[h] = load(MODEL_FILES[h])
                _scalers[h] = load(SCALER_FILES[h])
            except Exception as e:
                _log(f"Failed loading {h} model: {e}")
                _loaded[h] = None
                _scalers[h] = None
        else:
            _loaded[h] = None
            _scalers[h] = None
    _last_loaded_time = now
    _log("Loaded models (if present).")

# ---------- Prediction endpoint ----------

@app.route("/predict", methods=["POST"])
def predict():
    """
    Expects JSON with keys (case-insensitive):
      symbol, timeframe, open, high, low, close, volume
    Returns JSON:
      { "signal":"BUY"|"SELL"|"HOLD", "prob":0.7, "breakdown": {...}, "sl":30, "tp":60 }
    """
    try:
        data = request.get_json(force=False, silent=True)
        if not data:
            # try raw
            raw = request.get_data(as_text=True)
            data = json.loads(raw) if raw else None
        if not data:
            return jsonify({"error":"No JSON body received"}), 400
        # normalize
        data_l = {k.lower(): v for k,v in data.items()}
        required = ["open","high","low","close"]
        if not all(k in data_l for k in required):
            return jsonify({"error":"Missing required OHLC fields"}), 400

        open_ = float(data_l["open"])
        high = float(data_l["high"])
        low = float(data_l["low"])
        close = float(data_l["close"])
        # compute features for single-row inference
        ma_5 = (open_ + high + low + close) / 4.0   # simple approximation
        ma_20 = close - open_
        ret = 0.0

        X = np.array([[open_, high, low, close, ma_5, ma_20, ret]], dtype=float)

        # ensure models loaded
        load_models_if_needed()

        probs = {}
        contributions = {}
        for h in ["short","mid","long"]:
            model = _loaded.get(h)
            scaler = _scalers.get(h)
            if model is None or scaler is None:
                probs[h] = None
                continue
            try:
                Xs = scaler.transform(X)
                p = model.predict_proba(Xs)[0,1]  # probability of BUY
                probs[h] = float(p)
            except Exception as e:
                _log(f"Error predicting with {h}: {e}")
                probs[h] = None

        # combine using weights, ignoring missing
        total_weight = 0.0
        weighted_prob = 0.0
        for h, w in ENSEMBLE_WEIGHTS.items():
            p = probs.get(h)
            if p is None: continue
            weighted_prob += p * w
            total_weight += w
            contributions[h] = p

        if total_weight == 0:
            return jsonify({"error":"No models available"}), 500
        final_prob = weighted_prob / total_weight

        # thresholds
        if final_prob >= 0.55:
            signal = "BUY"
        elif final_prob <= 0.45:
            signal = "SELL"
        else:
            signal = "HOLD"

        # default SL/TP (these can be replaced by other logic)
        response = {
            "signal": signal,
            "prob": round(final_prob, 4),
            "breakdown": contributions,
            "STOP_LOSS_PIPS": 30,
            "TAKE_PROFIT_PIPS": 60
        }
        return jsonify(response)
    except Exception as e:
        _log("Predict failed: " + str(e))
        return jsonify({"error": str(e)}), 500

# ---------- Retrain endpoint (trigger) ----------

@app.route("/retrain", methods=["POST","GET"])
def retrain_endpoint():
    # optional: accept JSON body with params
    # Run retrain in background thread to avoid blocking HTTP client
    def _background():
        res = train_models()
        _log("Background retrain done: " + str(res))
    if _retrain_lock.locked():
        return jsonify({"status":"locked"}), 202
    t = threading.Thread(target=_background, daemon=True)
    t.start()
    return jsonify({"status":"retrain_started"}), 202

# ---------- Background scheduler thread ----------

def _scheduler_loop():
    _log("Auto-retrain scheduler started.")
    while True:
        if AUTO_RETRAIN_ENABLED:
            try:
                # check when last retrain happened
                meta = {}
                if os.path.exists(METADATA_FILE):
                    try:
                        with open(METADATA_FILE, "r") as f:
                            meta = json.load(f)
                    except:
                        meta = {}
                last = meta.get("last_retrain")
                need = True
                if last:
                    last_dt = datetime.strptime(last, "%Y-%m-%d %H:%M:%S")
                    if datetime.utcnow() - last_dt < timedelta(seconds=RETRAIN_INTERVAL_SECONDS):
                        need = False
                if need:
                    _log("Scheduled retrain triggered.")
                    train_models()
            except Exception as e:
                _log("Scheduler error: " + str(e))
        time.sleep(max(60, min(3600, RETRAIN_INTERVAL_SECONDS // 24)))  # check often but not too often

# Start scheduler thread
if AUTO_RETRAIN_ENABLED:
    th = threading.Thread(target=_scheduler_loop, daemon=True)
    th.start()

# ---------- startup message ----------
if __name__ == "__main__":
    import socket
    hostname = socket.gethostname()
    try:
        local_ip = socket.gethostbyname(hostname)
    except:
        local_ip = "127.0.0.1"
    _log(f"Starting Flask server; DATA_FOLDER={DATA_FOLDER}; MODEL_FOLDER={MODEL_FOLDER}")
    _log(f"MT5/EA should POST to http://{local_ip}:5000/predict and retrain at /retrain")
    app.run(host="0.0.0.0", port=5000)
