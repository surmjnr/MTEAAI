//+------------------------------------------------------------------+
//|                                                         HybridAI_EURUSD.mq5
//|  Hybrid day-swing trading EA with embedded ML models (MQL5 only) |
//|  - Two logistic regression models (short-term & medium-term)     |
//|  - Trains on historical OHLCV inside OnInit()                    |
//|  - Configurable risk management, SL/TP, trailing                  |
//|  - Dynamic lot sizing, max drawdown protection, max 3 trades dir  |
//|  - Chart display of AI confidence and last prediction             |
//|                                                                  |
//|  Author: ChatGPT (GPT-5 Thinking mini)                            |
//+------------------------------------------------------------------+
#property copyright "ChatGPT"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//-------------------- INPUTS --------------------
input ENUM_TIMEFRAMES  InpTimeframe = PERIOD_H1;     // Timeframe: M30, H1, H4
input double           RiskPerTradePercent = 1.0;   // % of balance to risk per trade
input int              StopLossPips = 40;           // Stop Loss in pips
input int              TakeProfitPips = 80;         // Take Profit in pips
input bool             UseTrailingStop = true;      // Use trailing stop
input int              TrailingStopPips = 30;       // Trailing stop distance in pips
input double           MaxDrawdownPercent = 20.0;   // Max drawdown before disabling trading
input double           MinConfidence = 0.60;        // Minimum confidence to place trade (0..1)
input int              MaxTradesPerDirection = 3;   // Max simultaneous trades per direction
input int              TrainingSamples = 1500;      // Number of historical samples used for training
input double           LearningRate = 0.01;         // Learning rate for gradient descent
input int              TrainingEpochs = 200;        // Training epochs for each model
input int              ShortHorizonBars = 3;        // Short-term horizon (in bars)
input int              MediumHorizonBars = 12;      // Medium-term horizon (in bars)
input bool             RetrainOnRestart = true;     // Retrain on EA init
input bool             TradeLong = true;            // Allow long trades
input bool             TradeShort = true;           // Allow short trades

//-------------------- GLOBALS --------------------
string SymbolPair;
double MaxBalanceSeen = 0.0;
bool TradingEnabled = true;

int    pipMultiplier = 10;    // for 5-digit or 3-digit symbols
double pointVal = 0.0;
double pip = 0.0001;

int    digits_local = 5;

// Logistic model weights: modelShort and modelMedium
// We'll use bias + features => weight array length = n_features + 1
double wShort[];  // weights for short-term logistic regression
double wMed[];    // weights for medium-term logistic regression

// Normalization arrays
double feat_min[];
double feat_max[];
int    nFeatures = 8;  // number of features used (see PrepareFeatures)

// Keep latest confidence and predictions to display
double last_conf_short = 0.0;
double last_conf_med = 0.0;
int    last_pred_short = 0;
int    last_pred_med = 0;

//-------------------- UTIL FUNCTIONS --------------------

// Print debugging only when necessary
void DBG(string s) { /*Comment(s);*/ }

// get pip size (e.g., 0.0001 for EURUSD) and multiplier for points->pips
void InitPip()
  {
   pointVal = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   digits_local = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   pipMultiplier = (digits_local>4) ? 10 : 1;
   pip = pointVal * pipMultiplier;
  }

// clamp
double clamp(double x,double lo,double hi){ if(x<lo) return lo; if(x>hi) return hi; return x; }

// Sigmoid
double sigmoid(double x) { return 1.0/(1.0+MathExp(-x)); }

// Normalize feature arrays based on feat_min/max
void NormalizeFeatureArray(double &arr[], int n)
  {
   for(int i=0;i<n;i++)
     {
      if(feat_max[i]-feat_min[i] > 0)
         arr[i] = (arr[i]-feat_min[i])/(feat_max[i]-feat_min[i]);
      else
         arr[i] = 0.0;
     }
  }

// Compute dot product
double dot(const double &weights[], const double &x[])
  {
   double s = 0.0;
   int n = ArraySize(weights);
   for(int i=0;i<n;i++) s += weights[i]*x[i];
   return s;
  }

// Initialize weight arrays
void InitWeights()
  {
   ArrayResize(wShort, nFeatures+1); // bias + features
   ArrayResize(wMed, nFeatures+1);
   for(int i=0;i<ArraySize(wShort);i++)
     {
      wShort[i] = MathRand()/double(RAND_MAX)*0.02-0.01;
      wMed[i]   = MathRand()/double(RAND_MAX)*0.02-0.01;
     }

   ArrayResize(feat_min, nFeatures);
   ArrayResize(feat_max, nFeatures);
   for(int i=0;i<nFeatures;i++){ feat_min[i]=1e9; feat_max[i]=-1e9; }
  }

//-------------------- DATA PREPARATION AND FEATURES --------------------
/*
 Features are computed from OHLCV windows and include:
 0: close - open (bar body)
 1: high - low (range)
 2: close - previous close (1-bar return)
 3: (close - SMA5)
 4: SMA5 - SMA20
 5: ATR(14)
 6: volume (raw)
 7: volatility (std dev of returns over 10 bars)

 These features use only OHLCV values from the selected timeframe.
*/

// Compute SMA for given series
double SMA(const double &arr[], int size, int idx, int period)
  {
   if(idx-period+1 < 0) return arr[idx];
   double s=0.0;
   for(int i=idx;i>idx-period;i--) s+=arr[i];
   return s/period;
  }

// Compute ATR using high/low/close arrays (simple implementation)
double ATR(const double &high[], const double &low[], const double &close[], int size, int idx, int period)
  {
   if(idx-period+1 < 0) return (high[idx]-low[idx]);
   double sum=0.0;
   for(int i=idx;i>idx-period;i--)
     {
      double tr = MathMax(high[i]-low[i], MathMax(MathAbs(high[i]-close[i+1>=size?size-1:i+1]), MathAbs(low[i]-close[i+1>=size?size-1:i+1])));
      sum += tr;
     }
   return sum/period;
  }

// Prepare feature vector for bar index i (0..n-1), using arrays returned by CopyRates (newest first)
void PrepareFeaturesForIndex(int idx, const MqlRates &rates[], int size, double &outFeatures[])
  {
   // We'll safely handle boundary by using available bars
   double open = rates[idx].open;
   double high = rates[idx].high;
   double low  = rates[idx].low;
   double close= rates[idx].close;
   double vol  = (double)rates[idx].tick_volume;

   // Build temporary arrays for close / high / low if needed
   static double closes[];
   static double highs[];
   static double lows[];
   static bool built=false;
   if(!built)
     {
      ArrayResize(closes, size);
      ArrayResize(highs, size);
      ArrayResize(lows, size);
      for(int i=0;i<size;i++){ closes[i]=rates[i].close; highs[i]=rates[i].high; lows[i]=rates[i].low; }
      built=true;
     }

   // Feature computations:
   double f0 = close - open;
   double f1 = high - low;
   double f2 = (idx+1 < size) ? (close - closes[idx+1]) : 0.0; // previous close is next index because newest first
   double sma5 = 0.0, sma20 = 0.0;
   // compute SMA5 & SMA20
   int p;
   p = MathMin(5, size-idx);
   double s5 = 0.0;
   for(int i=0;i<p;i++) s5 += closes[idx+i];
   sma5 = s5 / p;
   p = MathMin(20, size-idx);
   double s20 = 0.0;
   for(int i=0;i<p;i++) s20 += closes[idx+i];
   sma20 = s20 / p;
   double f3 = close - sma5;
   double f4 = sma5 - sma20;
   double f5 = ATR(highs, lows, closes, size, idx, 14);
   double f6 = vol;
   // volatility: std dev of returns (10 bars)
   int period = MathMin(10, size-idx);
   double mean = 0.0;
   for(int i=0;i<period-1;i++) mean += ((i+1 < size) ? (closes[idx+i] - closes[idx+i+1]) : 0.0);
   if(period>1) mean /= (period-1);
   double sd = 0.0;
   for(int i=0;i<period-1;i++)
     {
      double r = ((i+1 < size) ? (closes[idx+i] - closes[idx+i+1]) : 0.0) - mean;
      sd += r*r;
     }
   if(period>2) sd = MathSqrt(sd/(period-2)); else sd = 0.0;
   double f7 = sd;

   // pack
   outFeatures[0]=f0; outFeatures[1]=f1; outFeatures[2]=f2; outFeatures[3]=f3;
   outFeatures[4]=f4; outFeatures[5]=f5; outFeatures[6]=f6; outFeatures[7]=f7;
  }

//-------------------- LABELING --------------------
/*
 Label is 1 if close after horizon bars is higher than current close + tiny threshold,
 otherwise 0. This is binary classification for up/down.
*/

int ComputeLabel(const MqlRates &rates[], int size, int idx, int horizon)
  {
   // idx = index of current bar (0 = latest). Future bar index = idx - horizon (since newest first)
   int future_idx = idx - horizon;
   if(future_idx < 0 || future_idx >= size) return -1; // invalid
   double future_close = rates[future_idx].close;
   double current_close = rates[idx].close;
   double diff = future_close - current_close;
   // tiny threshold to avoid noise (we use pip)
   double threshold = pip * 0.5; // half a pip
   return (diff > threshold) ? 1 : 0;
  }

//-------------------- MODEL TRAINING --------------------

// Train logistic regression with gradient descent
void TrainLogisticRegression(double &weights[], const MqlRates &rates[], int size, int horizon, int samples)
  {
   // samples max limited by available size - horizon
   int maxSamples = MathMin(samples, size - horizon - 1);
   if(maxSamples < 50) { PrintFormat("Insufficient samples for training: %d", maxSamples); return; }

   // Prepare training X and y
   // We'll build arrays with newest-first ordering.
   double features[][];   // features[i][j]
   double labels[];
   ArrayResize(features, maxSamples);
   ArrayResize(labels, maxSamples);
   for(int i=0;i<maxSamples;i++)
     {
      ArrayResize(features[i], nFeatures+1); // we'll put bias term at features[i][0] = 1
     }

   // fill feat_min/max while building
   for(int i=0;i<maxSamples;i++)
     {
      int idx = i; // newest-first
      double fvec[];
      ArrayResize(fvec, nFeatures);
      PrepareFeaturesForIndex(idx, rates, size, fvec);

      // update feature min/max
      for(int j=0;j<nFeatures;j++)
        {
         if(fvec[j] < feat_min[j]) feat_min[j] = fvec[j];
         if(fvec[j] > feat_max[j]) feat_max[j] = fvec[j];
        }

      // temporarily store raw features in features array (bias will be added later)
      for(int j=0;j<nFeatures;j++) features[i][j+1] = fvec[j];
      features[i][0] = 1.0; // bias
      labels[i] = ComputeLabel(rates, size, idx, horizon);
      if(labels[i] < 0) labels[i] = 0;
     }

   // Now normalize features (except bias). We'll use feat_min/max
   for(int i=0;i<maxSamples;i++)
     {
      for(int j=1;j<=nFeatures;j++)
        {
         int fi = j-1;
         if(feat_max[fi]-feat_min[fi] > 0)
            features[i][j] = (features[i][j] - feat_min[fi]) / (feat_max[fi] - feat_min[fi]);
         else
            features[i][j] = 0.0;
        }
     }

   // weights already initialized (provided)
   int wSize = ArraySize(weights);
   // gradient descent
   for(int epoch=0; epoch<TrainingEpochs; epoch++)
     {
      // batch gradient over all samples
      double grad[]; ArrayResize(grad, wSize);
      for(int i=0;i<wSize;i++) grad[i]=0.0;

      for(int s=0;s<maxSamples;s++)
        {
         // compute dot
         double z = 0.0;
         for(int j=0;j<wSize;j++) z += weights[j] * features[s][j];
         double pred = sigmoid(z);
         double err = pred - labels[s]; // derivative of log-loss
         for(int j=0;j<wSize;j++) grad[j] += err * features[s][j];
        }
      // update weights
      for(int j=0;j<wSize;j++) weights[j] -= LearningRate * grad[j] / maxSamples;
     }

   // training finished
  }

//-------------------- PREDICTION (INFERENCE) --------------------
double PredictProbability(const double &weights[], const double features_raw[])
  {
   // features_raw length = nFeatures, need to normalize with feat_min/max, build augmented array
   double fx[];
   ArrayResize(fx, nFeatures+1);
   fx[0]=1.0;
   for(int i=0;i<nFeatures;i++)
     {
      if(feat_max[i]-feat_min[i] > 0)
         fx[i+1] = (features_raw[i] - feat_min[i])/(feat_max[i]-feat_min[i]);
      else fx[i+1] = 0.0;
     }
   // compute dot
   double s=0.0;
   for(int j=0;j<ArraySize(weights);j++) s += weights[j]*fx[j];
   double p = sigmoid(s);
   return p;
  }

//-------------------- TRADE SIGNAL GENERATION --------------------
int CountOpenPositionsByDirection(bool longDir)
  {
   int count=0;
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         string sym = PositionGetString(POSITION_SYMBOL);
         if(sym != Symbol()) continue;
         long type = PositionGetInteger(POSITION_TYPE);
         if(longDir && type==POSITION_TYPE_BUY) count++;
         if(!longDir && type==POSITION_TYPE_SELL) count++;
        }
     }
   return count;
  }

// Compute lot size based on risk percent and SL (in pips)
double ComputeLotSize(double riskPercent, int slPips)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (riskPercent/100.0);
   // pip value per lot:
   double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE); // value of one tick for 1 lot
   double tickSize  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   // pip in points:
   double pip_in_points = pip / tickSize;
   double pipValuePerLot = (tickValue * pip_in_points);
   if(pipValuePerLot <= 0) pipValuePerLot = 10.0; // fallback approximate
   double slValuePerLot = slPips * pipValuePerLot;
   double lot = riskMoney / slValuePerLot;
   // clamp to allowed volume range
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   if(minLot<=0) minLot = 0.01;
   if(maxLot<=0) maxLot = 100.0;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   // adjust to step
   int steps = (int)MathFloor((lot - minLot) / step + 0.5);
   lot = minLot + steps * step;
   lot = NormalizeDouble(lot, (int)MathMax(0.0, 2.0));
   return lot;
  }

// Place order (market)
bool PlaceOrder(bool buy, double lot, int slPips, int tpPips, double confidence)
  {
   // conditions check
   if(!TradingEnabled) return false;

   // compute prices
   double price = buy ? SymbolInfoDouble(Symbol(), SYMBOL_ASK) : SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double slPrice, tpPrice;
   if(buy)
     {
      slPrice = price - slPips * pip;
      tpPrice = price + tpPips * pip;
     }
   else
     {
      slPrice = price + slPips * pip;
      tpPrice = price - tpPips * pip;
     }
   // create request via CTrade
   trade.SetExpertMagicNumber(123456);
   trade.SetDeviationInPoints(10);
   bool ok=false;
   if(buy)
      ok = trade.Buy(lot, NULL, slPrice, tpPrice, StringFormat("AI buy conf=%.2f", confidence));
   else
      ok = trade.Sell(lot, NULL, slPrice, tpPrice, StringFormat("AI sell conf=%.2f", confidence));
   if(!ok)
     {
      Print("Trade failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      return false;
     }
   else
     {
      PrintFormat("Trade placed %s lot=%.2f SL=%d TP=%d conf=%.2f", buy?"BUY":"SELL", lot, slPips, tpPips, confidence);
      return true;
     }
  }

//-------------------- TRADE MANAGEMENT (Trailing + exits) --------------------
void ManagePositions()
  {
   // trailing stop and general management
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != Symbol()) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur_price = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(Symbol(), SYMBOL_BID) : SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      // Trailing stop logic if enabled
      if(UseTrailingStop && TrailingStopPips>0)
        {
         if(type==POSITION_TYPE_BUY)
           {
            double newSL = cur_price - TrailingStopPips * pip;
            if(newSL>sl && cur_price - price_open > TrailingStopPips * pip)
              {
               // modify position
               trade.PositionModify(ticket, newSL, tp);
              }
           }
         else
           {
            double newSL = cur_price + TrailingStopPips * pip;
            if(newSL<sl && price_open - cur_price > TrailingStopPips * pip)
              {
               trade.PositionModify(ticket, newSL, tp);
              }
           }
        }
     }
  }

//-------------------- ONINIT: LOAD DATA & TRAIN MODELS --------------------
int OnInit()
  {
   SymbolPair = Symbol();
   InitPip();
   PrintFormat("HybridAI_EURUSD init for %s timeframe %d", SymbolPair, InpTimeframe);

   // guard
   if(SymbolPair != "EURUSD") Print("Warning: This EA tuned for EURUSD but will run on any symbol.");

   // initialize weights & arrays
   InitWeights();

   // Copy historical data for training: we'll request TrainingSamples + horizon + margin
   int needed = TrainingSamples + MathMax(ShortHorizonBars, MediumHorizonBars) + 20;
   MqlRates rates[];
   int copied = CopyRates(Symbol(), InpTimeframe, 0, needed, rates);
   if(copied <= MathMax(ShortHorizonBars, MediumHorizonBars) + 50)
     {
      Print("Not enough bars to train - using fewer samples");
     }
   if(copied <= 30)
     {
      Print("ERROR: insufficient historical data for training. EA will still run but predictions will be unreliable.");
      return(INIT_FAILED);
     }

   // Ensure newest-first ordering: CopyRates returns newest-first when time_from=0
   // Train both models
   if(RetrainOnRestart)
     {
      Print("Training short-term model...");
      TrainLogisticRegression(wShort, rates, copied, ShortHorizonBars, TrainingSamples);
      Print("Short-term model trained.");

      Print("Training medium-term model...");
      TrainLogisticRegression(wMed, rates, copied, MediumHorizonBars, TrainingSamples);
      Print("Medium-term model trained.");
     }

   MaxBalanceSeen = AccountInfoDouble(ACCOUNT_BALANCE);
   TradingEnabled = true;

   // Chart objects: create label by Comment updates on OnTick

   return(INIT_SUCCEEDED);
  }

//-------------------- ONTICK: PREDICTION & TRADING --------------------
void OnTick()
  {
   // update max balance seen and check drawdown
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   MaxBalanceSeen = MathMax(MaxBalanceSeen, balance);
   double drawdownPercent = (MaxBalanceSeen - balance) / MaxBalanceSeen * 100.0;
   if(drawdownPercent >= MaxDrawdownPercent)
     {
      TradingEnabled = false;
      Comment("Trading disabled: Max drawdown exceeded (", DoubleToString(drawdownPercent,2), "%) ");
      return;
     }
   else
      TradingEnabled = true;

   // Manage existing positions (trailing stop etc)
   ManagePositions();

   // get latest bar data for feature calculation
   MqlRates rates[];
   int copied = CopyRates(Symbol(), InpTimeframe, 0, 1000, rates);
   if(copied < 50) return;

   // Build features for index 0 (latest completed bar is index 1 if we want bar closed)
   // We'll use the last closed bar - index 1 is last closed (index 0 is forming)
   int idx = 1;
   double features_raw[];
   ArrayResize(features_raw, nFeatures);
   PrepareFeaturesForIndex(idx, rates, copied, features_raw);

   // Predict
   double pShort = PredictProbability(wShort, features_raw);
   double pMed   = PredictProbability(wMed,   features_raw);
   last_conf_short = pShort;
   last_conf_med   = pMed;
   last_pred_short = (pShort >= 0.5) ? 1 : 0;
   last_pred_med   = (pMed >= 0.5) ? 1 : 0;

   // Combine decisions: We take action when both models agree (both up or both down)
   bool agree = (last_pred_short == last_pred_med);

   // require minimum confidence: both confidences above threshold OR weighted average above threshold
   double avg_conf = (pShort + pMed)/2.0;

   // Direction: 1 => buy, 0 => sell
   if(agree && avg_conf >= MinConfidence && TradingEnabled)
     {
      bool wantBuy = (last_pred_short==1);
      // check allowed directions
      if((wantBuy && !TradeLong) || (!wantBuy && !TradeShort))
         { /* not allowed direction */ }
      else
        {
         // check max trades per direction
         int openCount = CountOpenPositionsByDirection(wantBuy);
         if(openCount >= MaxTradesPerDirection) { /* too many trades in that direction */ }
         else
           {
            // compute lot size based on SL and risk
            double lot = ComputeLotSize(RiskPerTradePercent, StopLossPips);
            // place trade
            PlaceOrder(wantBuy, lot, StopLossPips, TakeProfitPips, avg_conf);
           }
        }
     }

   // update chart display
   string status = TradingEnabled ? "ENABLED" : "DISABLED";
   string info = StringFormat("HybridAI EURUSD %s TF:%s\nShortConf: %.2f Pred:%d\nMedConf: %.2f Pred:%d\nAvgConf: %.2f\nMaxBal: %.2f Drawdown: %.2f%%\nTradesLong:%d Short:%d\nStatus:%s",
                 Symbol(), EnumToString(InpTimeframe), pShort, last_pred_short, pMed, last_pred_med, avg_conf,
                 MaxBalanceSeen, drawdownPercent,
                 CountOpenPositionsByDirection(true), CountOpenPositionsByDirection(false),
                 status);
   Comment(info);
  }

//-------------------- ONDEINIT --------------------
void OnDeinit(const int reason)
  {
   Comment("");
  }

//-------------------- A SHORT NOTE ON ERROR HANDLING --------------------
// The code checks for common errors (insufficient bars, trade failures). In live settings,
// ensure trading is enabled for the account, symbol and volume constraints met, and that
// the EA has permission to trade.

// End of file
