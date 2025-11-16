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
import pandas as pd
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
