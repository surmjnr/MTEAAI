//+------------------------------------------------------------------+
//| PrecisionMomentum_11conds.mq5                                    |
//| Implements EMA9/EMA21 + Parabolic SAR + RSI + MACD histogram     |
//| 11-condition rule set (M30, H1, H4 bias mandatory) + auto lot    |
//| SL via ATR * multiplier, TP = R * SL, move to breakeven at 1R   |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
input double  RiskPercent      = 5.0;      // % of equity to risk per trade (0 to disable)
input double  FixedLot         = 0.10;     // fallback fixed lot if RiskPercent = 0
input double  MaxLot           = 2.0;      // maximum lot
input double  ATRMultiplier    = 1.5;      // ATR * multiplier for SL
input int     ATRPeriod        = 14;       // ATR period
input double  TP_Multiple      = 2.0;      // TP = TP_Multiple * SL
input int     Threshold        = 1;        // minimum number of 1s 
input int     MagicNumber      = 20251103; // EA magic number
input int     SlippagePoints   = 6;        // slippage in points
input bool    MoveToBreakEven  = true;     // move SL to entry when 1R reached
input bool    AllowLong        = true;
input bool    AllowShort       = true;

//--- helper constants
#define BUY_SIDE  1
#define SELL_SIDE -1

//+------------------------------------------------------------------+
//| Utils - get indicator values                                      |
//+------------------------------------------------------------------+
double EMA(string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
  double buf[];
  int handle = iMA(sym, tf, period, 0, MODE_EMA, PRICE_CLOSE);
  if(handle == INVALID_HANDLE) return 0.0;
  if(CopyBuffer(handle, 0, shift, 1, buf) <= 0) { IndicatorRelease(handle); return 0.0; }
  IndicatorRelease(handle);
  return buf[0];
}

double SARv(string sym, ENUM_TIMEFRAMES tf, double step, double maxv, int shift)
{
  double buf[];
  int handle = iSAR(sym, tf, step, maxv);
  if(handle==INVALID_HANDLE) return 0.0;
  if(CopyBuffer(handle,0,shift,1,buf)<=0) { IndicatorRelease(handle); return 0.0; }
  IndicatorRelease(handle);
  return buf[0];
}

double RSIv(string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
  double buf[];
  int handle = iRSI(sym, tf, period, PRICE_CLOSE);
  if(handle==INVALID_HANDLE) return 0.0;
  if(CopyBuffer(handle,0,shift,1,buf)<=0) { IndicatorRelease(handle); return 0.0; }
  IndicatorRelease(handle);
  return buf[0];
}

double ATRv(string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
  double buf[];
  int handle = iATR(sym, tf, period);
  if(handle==INVALID_HANDLE) return 0.0;
  if(CopyBuffer(handle,0,shift,1,buf)<=0) { IndicatorRelease(handle); return 0.0; }
  IndicatorRelease(handle);
  return buf[0];
}

// MACD histogram: buffer index 2 usually histogram
double MACD_hist(string sym, ENUM_TIMEFRAMES tf, int fast, int slow, int signal, int shift)
{
  double buf[];
  int handle = iMACD(sym, tf, fast, slow, signal, PRICE_CLOSE);
  if(handle==INVALID_HANDLE) return 0.0;
  // histogram is buffer index 2 in MQL5 built-in MACD
  if(CopyBuffer(handle,2,shift,2,buf) <= 0) { IndicatorRelease(handle); return 0.0; }
  IndicatorRelease(handle);
  // buf[0] = current hist, buf[1] = previous hist
  return buf[0];
}

// MACD histogram previous (for slope check)
double MACD_hist_prev(string sym, ENUM_TIMEFRAMES tf, int fast, int slow, int signal, int shift)
{
  double buf[];
  int handle = iMACD(sym, tf, fast, slow, signal, PRICE_CLOSE);
  if(handle==INVALID_HANDLE) return 0.0;
  if(CopyBuffer(handle,2,shift+1,1,buf) <= 0) { IndicatorRelease(handle); return 0.0; }
  IndicatorRelease(handle);
  return buf[0];
}

// get close price of timeframe candle 0
double CloseTF(string sym, ENUM_TIMEFRAMES tf)
{
  return iClose(sym, tf, 0);
}

// get close price of previous candle (shift 1)
double CloseTF_prev(string sym, ENUM_TIMEFRAMES tf)
{
  return iClose(sym, tf, 1);
}

// get EMA values current and previous for cross detection
void EMA_values(string sym, ENUM_TIMEFRAMES tf, int pFast, int pSlow, double &fastNow, double &slowNow, double &fastPrev, double &slowPrev)
{
  fastNow  = EMA(sym, tf, pFast, 0);
  slowNow  = EMA(sym, tf, pSlow, 0);
  fastPrev = EMA(sym, tf, pFast, 1);
  slowPrev = EMA(sym, tf, pSlow, 1);
}

// get SAR current
double SAR_current(string sym, ENUM_TIMEFRAMES tf) { return SARv(sym, tf, 0.02, 0.2, 0); }

// count buy conditions for a specific TF (returns how many of the 5 buy conditions are met)
int CountBuyConditionsTF(string sym, ENUM_TIMEFRAMES tf)
{
  int met = 0;

  double fastNow, slowNow, fastPrev, slowPrev;
  EMA_values(sym, tf, 9, 21, fastNow, slowNow, fastPrev, slowPrev);

  // 1) EMA9 crosses above EMA21 (cross detection: prev fast <= prev slow and now fast > now slow)
  if(fastPrev <= slowPrev && fastNow > slowNow) met++;

  // 2) Parabolic SAR dots below candles -> bullish (close > sar)
  //double close = CloseTF(sym, tf);
  //double sar = SAR_current(sym, tf);
  //if(close > sar) met++;

  // 3) RSI > 55 but < 70 (we count as true if RSI > 55 and RSI < 70)
  //double rsi = RSIv(sym, tf, 14, 0);
  //if(rsi > 45.0 && rsi < 70.0) met++;

  // 4) MACD histogram showing upward trend (rising momentum)
  //double hist    = MACD_hist(sym, tf, 12, 26, 9, 0);
  //double histPrev = MACD_hist_prev(sym, tf, 12, 26, 9, 0);
  //if(hist > histPrev) met++;  // rising MACD histogram = upward momentum

  // 5) Price closes above both EMAs (close > fastNow and close > slowNow)
  //if(close > fastNow && close > slowNow) met++;

  return met;
}

// count sell conditions for a specific TF (5 conditions)
int CountSellConditionsTF(string sym, ENUM_TIMEFRAMES tf)
{
  int met = 0;

  double fastNow, slowNow, fastPrev, slowPrev;
  EMA_values(sym, tf, 9, 21, fastNow, slowNow, fastPrev, slowPrev);

  // 1) EMA9 crosses below EMA21
  if(fastPrev >= slowPrev && fastNow < slowNow) met++;

  // 2) Parabolic SAR dots above candles -> bearish (close < sar)
  //double close = CloseTF(sym, tf);
 // double sar = SAR_current(sym, tf);
  //if(close < sar) met++;

  // 3) RSI < 45 but > 30
  //double rsi = RSIv(sym, tf, 14, 0);
  //if(rsi < 50.0 && rsi > 25.0) met++;

  // 4) MACD histogram showing downward trend (falling momentum)
  //double hist    = MACD_hist(sym, tf, 12, 26, 9, 0);
  //double histPrev = MACD_hist_prev(sym, tf, 12, 26, 9, 0);
  //if(hist < histPrev) met++;  // falling MACD histogram = downward momentum

  // 5) Price closes below both EMAs
  //if(close < fastNow && close < slowNow) met++;

  return met;
}

// calculate lot size based on RiskPercent and stop loss in points
double CalculateLotByRisk(string sym, double stopLossPoints)
{
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   // Use fixed lot if RiskPercent disabled
   if (RiskPercent <= 0.0000001)
   {
      double lot = FixedLot;
      lot = MathMax(minLot, MathMin(maxLot, lot));
      lot = MathFloor(lot / step) * step;
      return NormalizeDouble(lot, 2);
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (RiskPercent / 100.0);

   double tick_value = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if (tick_size <= 0.0) tick_size = SymbolInfoDouble(sym, SYMBOL_POINT);

   double valuePerPointPerLot = (tick_value / tick_size);
   if (stopLossPoints <= 0.0 || valuePerPointPerLot <= 0.0)
   {
      Print("Lot fallback: invalid SL points/tick info");
      return MathMax(minLot, FixedLot);
   }

   // Calculate initial lot
   double rawLot = riskAmount / (stopLossPoints * valuePerPointPerLot);

   // Guarantee non-zero by minimum lot rule
   if (rawLot < minLot)
   {
      // fallback: risk a fixed % of equity regardless of SL width
      rawLot = MathMax(minLot, (equity * 0.001) / valuePerPointPerLot);
   }

   // Cap at maximums
   rawLot = MathMin(rawLot, maxLot);
   rawLot = MathMin(rawLot, MaxLot);

   // Align to step
   rawLot = MathFloor(rawLot / step) * step;
   return NormalizeDouble(rawLot, 2);
}



// check if this EA has an open position on symbol in a given direction
bool HasPosition(int side)
{
  for(int i=0; i<PositionsTotal(); i++)
  {
    ulong ticket = PositionGetTicket(i);
    if(ticket == 0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
    if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
    string sym = PositionGetString(POSITION_SYMBOL);
    if(StringCompare(sym, _Symbol) != 0) continue;
    long type = PositionGetInteger(POSITION_TYPE);
    if(side==BUY_SIDE && type==POSITION_TYPE_BUY) return true;
    if(side==SELL_SIDE && type==POSITION_TYPE_SELL) return true;
  }
  return false;
}

ulong GetPositionTicket(int side)
{
  for(int i=0; i<PositionsTotal(); i++)
  {
    ulong ticket = PositionGetTicket(i);
    if(ticket == 0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
    if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
    string sym = PositionGetString(POSITION_SYMBOL);
    if(StringCompare(sym, _Symbol) != 0) continue;
    long type = PositionGetInteger(POSITION_TYPE);
    if(side==BUY_SIDE && type==POSITION_TYPE_BUY) return ticket;
    if(side==SELL_SIDE && type==POSITION_TYPE_SELL) return ticket;
  }
  return 0;
}

// modify position SL/TP
bool ModifyPositionSLTP(ulong ticket, double sl, double tp)
{
  if(ticket==0) return false;
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  bool ok = trade.PositionModify(ticket, sl, tp);
  if(!ok) Print("Modify failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
  return ok;
}

// place market order with SL/TP
bool OpenMarketOrder(int side, double lot, double slPrice, double tpPrice)
{
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  bool res=false;
  if(side==BUY_SIDE)
    res = trade.Buy(lot, NULL, 0.0, slPrice, tpPrice, "PM_11_BUY");
  else
    res = trade.Sell(lot, NULL, 0.0, slPrice, tpPrice, "PM_11_SELL");
  if(!res) Print("Order failed: code=", trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription());
  return res;
}

// move SL to breakeven when profit >= 1R
void CheckMoveToBreakEven()
{
  if(!MoveToBreakEven) return;
  // for buys
  ulong buyTicket = GetPositionTicket(BUY_SIDE);
  if(buyTicket!=0)
  {
    if(!PositionSelectByTicket(buyTicket)) return;
    double entry = PositionGetDouble(POSITION_PRICE_OPEN);
    double sl = PositionGetDouble(POSITION_SL);
    double volume = PositionGetDouble(POSITION_VOLUME);
    if(entry<=0) return;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double profitPoints = (SymbolInfoDouble(_Symbol, SYMBOL_BID) - entry) / point;
    double slPoints = (entry - sl) / point;
    if(slPoints > 0 && profitPoints >= slPoints)
    {
      // set sl to entry
      ModifyPositionSLTP(buyTicket, entry, PositionGetDouble(POSITION_TP));
      Print("Moved BUY SL to breakeven for ticket ", buyTicket);
    }
  }
  // for sells
  ulong sellTicket = GetPositionTicket(SELL_SIDE);
  if(sellTicket!=0)
  {
    if(!PositionSelectByTicket(sellTicket)) return;
    double entry = PositionGetDouble(POSITION_PRICE_OPEN);
    double sl = PositionGetDouble(POSITION_SL);
    double volume = PositionGetDouble(POSITION_VOLUME);
    if(entry<=0) return;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double profitPoints = (entry - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / point;
    double slPoints = (sl - entry) / point;
    if(slPoints > 0 && profitPoints >= slPoints)
    {
      ModifyPositionSLTP(sellTicket, entry, PositionGetDouble(POSITION_TP));
      Print("Moved SELL SL to breakeven for ticket ", sellTicket);
    }
  }
}

//--- calculate SL/TP based on recent candles + ATR
void CalculateDynamicSLTP(string sym, int side, ENUM_TIMEFRAMES tf,
                          double entryPrice, double &slPrice, double &tpPrice,
                          double atrMult, double rewardR)
{
   int lookback = 5; // lookback candles for recent high/low
   double atr = ATRv(sym, tf, 14, 0);
   if (atr <= 0.0)
      atr = SymbolInfoDouble(sym, SYMBOL_POINT) * 100; // fallback
   
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double recentHigh = iHigh(sym, tf, iHighest(sym, tf, MODE_HIGH, lookback, 1));
   double recentLow  = iLow(sym, tf, iLowest(sym, tf, MODE_LOW, lookback, 1));

   double buffer = atrMult * atr;

   if (side == BUY_SIDE)
   {
      slPrice = MathMin(recentLow, entryPrice - buffer);
      tpPrice = entryPrice + (entryPrice - slPrice) * rewardR;
   }
   else if (side == SELL_SIDE)
   {
      slPrice = MathMax(recentHigh, entryPrice + buffer);
      tpPrice = entryPrice - (slPrice - entryPrice) * rewardR;
   }
}



//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   string sym = _Symbol;
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)_Period; // use the chart's current timeframe

   // Count buy/sell conditions only for the current chart timeframe
   int buyCount  = CountBuyConditionsTF(sym, tf);
   int sellCount = CountSellConditionsTF(sym, tf);

   // Check thresholds (based only on this TF)
   bool readyBuy  = (buyCount  >= Threshold) && AllowLong;
   bool readySell = (sellCount >= Threshold) && AllowShort;

   double ask   = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(sym, SYMBOL_BID);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

   // --- BUY SETUP ---
   if(readyBuy && !HasPosition(BUY_SIDE))
   {
      double sl_price, tp_price;
         CalculateDynamicSLTP(sym, BUY_SIDE, tf, ask, sl_price, tp_price, ATRMultiplier, TP_Multiple);
      double stopPoints = MathAbs(ask - sl_price) / point;

      double lot = CalculateLotByRisk(sym, stopPoints);
      if(lot > 0.0)
      {
         if(OpenMarketOrder(BUY_SIDE, lot, sl_price, tp_price))
         {
            Print("Opened BUY lot=", lot,
                  " on ", EnumToString(tf),
                  " SL=", DoubleToString(sl_price, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                  " TP=", DoubleToString(tp_price, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)));
         }
      }
   }

   // --- SELL SETUP ---
   if(readySell && !HasPosition(SELL_SIDE))
   {
      double sl_price_s, tp_price_s;
         CalculateDynamicSLTP(sym, SELL_SIDE, tf, bid, sl_price_s, tp_price_s, ATRMultiplier, TP_Multiple);
      double stopPoints_s = MathAbs(sl_price_s - bid) / point;


      double lot2 = CalculateLotByRisk(sym, stopPoints_s);
      if(lot2 > 0.0)
      {
         if(OpenMarketOrder(SELL_SIDE, lot2, sl_price_s, tp_price_s))
         {
            Print("Opened SELL lot=", lot2,
                  " on ", EnumToString(tf),
                  " SL=", DoubleToString(sl_price_s, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                  " TP=", DoubleToString(tp_price_s, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)));
         }
      }
   }

   // Move SL to breakeven when 1R reached
   CheckMoveToBreakEven();
}
//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
  Print("PrecisionMomentum_11conds initialized for ", _Symbol);
  return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  // nothing
}

//+------------------------------------------------------------------+
