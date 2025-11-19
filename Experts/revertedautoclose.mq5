//+------------------------------------------------------------------+
//| PrecisionMomentum_11conds_triple_orders_breakeven.mq5           |
//| Modified: opens 3 scaled orders per signal, closes opposite ones |
//|           move SL to breakeven if the order with minimum TP was |
//|           closed (closest TP to entry)                           |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
input double  RiskPercent      = 3.0;      // % of equity to risk per trade (0 to disable)
input double  FixedLot         = 0.10;     // fallback fixed lot if RiskPercent = 0
input double  MaxLot           = 2.0;      // maximum lot
input double  ATRMultiplier    = 1.5;      // ATR * multiplier for SL
input int     ATRPeriod        = 14;       // ATR period
input double  TP_Multiple      = 2.0;      // TP = TP_Multiple * SL (used to compute base TP)
input int     Threshold        = 1;        // minimum number of 1s 
input int     MagicNumber      = 20251103; // EA magic number
input int     SlippagePoints   = 6;        // slippage in points
input bool    MoveToBreakEven  = true;     // move SL to entry when 1R reached
input bool    AllowLong        = true;
input bool    AllowShort       = true;

//--- helper constants
#define BUY_SIDE  1
#define SELL_SIDE -1

//--- State to track triples so we can detect which ticket closed
ulong  ticketsBuy[];            // tickets for current buy-side triple group
double tpsBuy[];               // their TP values
bool   breakevenBuyApplied = false;
int    initialCountBuy = 0;

ulong  ticketsSell[];           // tickets for current sell-side triple group
double tpsSell[];
bool   breakevenSellApplied = false;
int    initialCountSell = 0;

// (Existing utility indicator functions unchanged) --------------------------------
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

double MACD_hist(string sym, ENUM_TIMEFRAMES tf, int fast, int slow, int signal, int shift)
{
  double buf[];
  int handle = iMACD(sym, tf, fast, slow, signal, PRICE_CLOSE);
  if(handle==INVALID_HANDLE) return 0.0;
  if(CopyBuffer(handle,2,shift,2,buf) <= 0) { IndicatorRelease(handle); return 0.0; }
  IndicatorRelease(handle);
  return buf[0];
}

double MACD_hist_prev(string sym, ENUM_TIMEFRAMES tf, int fast, int slow, int signal, int shift)
{
  double buf[];
  int handle = iMACD(sym, tf, fast, slow, signal, PRICE_CLOSE);
  if(handle==INVALID_HANDLE) return 0.0;
  if(CopyBuffer(handle,2,shift+1,1,buf) <= 0) { IndicatorRelease(handle); return 0.0; }
  IndicatorRelease(handle);
  return buf[0];
}

double CloseTF(string sym, ENUM_TIMEFRAMES tf)
{
  return iClose(sym, tf, 0);
}

double CloseTF_prev(string sym, ENUM_TIMEFRAMES tf)
{
  return iClose(sym, tf, 1);
}

void EMA_values(string sym, ENUM_TIMEFRAMES tf, int pFast, int pSlow, double &fastNow, double &slowNow, double &fastPrev, double &slowPrev)
{
  fastNow  = EMA(sym, tf, pFast, 0);
  slowNow  = EMA(sym, tf, pSlow, 0);
  fastPrev = EMA(sym, tf, pFast, 1);
  slowPrev = EMA(sym, tf, pSlow, 1);
}

double SAR_current(string sym, ENUM_TIMEFRAMES tf) { return SARv(sym, tf, 0.02, 0.2, 0); }

int CountBuyConditionsTF(string sym, ENUM_TIMEFRAMES tf)
{
  int met = 0;

  double fastNow, slowNow, fastPrev, slowPrev;
  EMA_values(sym, tf, 9, 21, fastNow, slowNow, fastPrev, slowPrev);

  if(fastPrev <= slowPrev && fastNow > slowNow) met++;

  return met;
}

int CountSellConditionsTF(string sym, ENUM_TIMEFRAMES tf)
{
  int met = 0;

  double fastNow, slowNow, fastPrev, slowPrev;
  EMA_values(sym, tf, 9, 21, fastNow, slowNow, fastPrev, slowPrev);

  if(fastPrev >= slowPrev && fastNow < slowNow) met++;

  return met;
}

// calculate lot size based on RiskPercent and stop loss in points
double CalculateLotByRisk(string sym, double stopLossPoints)
{
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

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

   double rawLot = riskAmount / (stopLossPoints * valuePerPointPerLot);

   if (rawLot < minLot)
   {
      rawLot = MathMax(minLot, (equity * 0.001) / valuePerPointPerLot);
   }

   rawLot = MathMin(rawLot, maxLot);
   rawLot = MathMin(rawLot, MaxLot);

   rawLot = MathFloor(rawLot / step) * step;
   return NormalizeDouble(rawLot, 2);
}

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

bool ModifyPositionSLTP(ulong ticket, double sl, double tp)
{
  if(ticket==0) return false;
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  bool ok = trade.PositionModify(ticket, sl, tp);
  if(!ok) Print("Modify failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
  return ok;
}

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

void CheckMoveToBreakEven()
{
  if(!MoveToBreakEven) return;
  // iterate all positions of this EA on this symbol
  for(int i=PositionsTotal()-1; i>=0; i--)
  {
    ulong ticket = PositionGetTicket(i);
    if(ticket==0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
    if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
    string sym = PositionGetString(POSITION_SYMBOL);
    if(StringCompare(sym, _Symbol) != 0) continue;

    long type = PositionGetInteger(POSITION_TYPE);
    double entry = PositionGetDouble(POSITION_PRICE_OPEN);
    double sl = PositionGetDouble(POSITION_SL);
    double tp = PositionGetDouble(POSITION_TP);
    if(entry<=0 || sl==0) continue;

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if(type==POSITION_TYPE_BUY)
    {
      double profitPoints = (SymbolInfoDouble(_Symbol, SYMBOL_BID) - entry) / point;
      double slPoints = (entry - sl) / point;
      if(slPoints > 0 && profitPoints >= slPoints)
      {
        ModifyPositionSLTP(ticket, entry, tp);
        Print("Moved BUY SL to breakeven for ticket ", ticket);
      }
    }
    else if(type==POSITION_TYPE_SELL)
    {
      double profitPoints = (entry - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / point;
      double slPoints = (sl - entry) / point;
      if(slPoints > 0 && profitPoints >= slPoints)
      {
        ModifyPositionSLTP(ticket, entry, tp);
        Print("Moved SELL SL to breakeven for ticket ", ticket);
      }
    }
  }
}

//--- calculate SL/TP based on recent candles + ATR (unchanged)
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

// Close all positions of given side (that belong to this EA on current symbol)
bool ClosePositionsBySide(int side)
{
  bool anyClosed = false;
  for(int i=PositionsTotal()-1; i>=0; i--)
  {
    ulong ticket = PositionGetTicket(i);
    if(ticket == 0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
    if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
    string sym = PositionGetString(POSITION_SYMBOL);
    if(StringCompare(sym, _Symbol) != 0) continue;
    long type = PositionGetInteger(POSITION_TYPE);
    if(side==BUY_SIDE && type==POSITION_TYPE_BUY)
    {
      trade.SetExpertMagicNumber(MagicNumber);
      trade.SetDeviationInPoints(SlippagePoints);
      if(trade.PositionClose(ticket))
      {
        anyClosed = true;
        Print("Closed BUY position ticket ", ticket);
      }
      else Print("Failed to close BUY ticket ", ticket, " rc=", trade.ResultRetcode());
    }
    else if(side==SELL_SIDE && type==POSITION_TYPE_SELL)
    {
      trade.SetExpertMagicNumber(MagicNumber);
      trade.SetDeviationInPoints(SlippagePoints);
      if(trade.PositionClose(ticket))
      {
        anyClosed = true;
        Print("Closed SELL position ticket ", ticket);
      }
      else Print("Failed to close SELL ticket ", ticket, " rc=", trade.ResultRetcode());
    }
  }

  // reset tracking when we force-close the side
  if(side==BUY_SIDE) { ArrayFree(ticketsBuy); ArrayFree(tpsBuy); initialCountBuy=0; breakevenBuyApplied=false; }
  if(side==SELL_SIDE){ ArrayFree(ticketsSell); ArrayFree(tpsSell); initialCountSell=0; breakevenSellApplied=false; }

  return anyClosed;
}

// Open three scaled market orders: split lot into 3 equal parts (rounded to step)
bool OpenTripleOrders(int side, double totalLot, double slPrice, double baseTpPrice)
{
  // compute entry price depending on side
  double entry = (side==BUY_SIDE) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

  // compute full TP distance in points
  double fullTpPoints = MathAbs(baseTpPrice - entry) / point;
  if(fullTpPoints <= 0)
  {
    Print("Invalid TP distance, abort triple open");
    return false;
  }

  // compute individual TP distances: full, 1/3, 2/3 (example order: full, 1/3, 2/3)
  double tpPoints_full = fullTpPoints;
  double tpPoints_one  = fullTpPoints / 3.0;
  double tpPoints_two  = fullTpPoints * 2.0 / 3.0;

  // convert to price levels
  double tp_full = (side==BUY_SIDE) ? (entry + tpPoints_full * point) : (entry - tpPoints_full * point);
  double tp_one  = (side==BUY_SIDE) ? (entry + tpPoints_one  * point) : (entry - tpPoints_one  * point);
  double tp_two  = (side==BUY_SIDE) ? (entry + tpPoints_two  * point) : (entry - tpPoints_two  * point);

  // split totalLot into 3 parts respecting symbol volume step
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

  if(totalLot < minLot) totalLot = minLot;
  if(totalLot > maxLot) totalLot = maxLot;

  double part = MathFloor((totalLot / 3.0) / step) * step;
  if(part < step) part = step; // ensure positive

  double lot1 = part;
  double lot2 = part;
  double lot3 = part;

  // distribute any leftover due to rounding into lot1
  double used = lot1 + lot2 + lot3;
  double leftover = MathFloor(((totalLot - used) / step)) * step;
  if(leftover < 0) leftover = 0;
  lot1 = lot1 + leftover;

  // final normalization
  lot1 = MathMin(MathMax(lot1, minLot), maxLot);
  lot2 = MathMin(MathMax(lot2, minLot), maxLot);
  lot3 = MathMin(MathMax(lot3, minLot), maxLot);

  // set trade params
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  bool ok1 = OpenMarketOrder(side, lot1, slPrice, tp_full);
  bool ok2 = OpenMarketOrder(side, lot2, slPrice, tp_one);
  bool ok3 = OpenMarketOrder(side, lot3, slPrice, tp_two);

  // Return true if at least one succeeded. Caller will refresh actual positions that exist.
  return (ok1 || ok2 || ok3);
}

//--- helper: count current positions for this EA and symbol for a side
int CountPositionsForSide(int side)
{
  int cnt = 0;
  for(int i=0; i<PositionsTotal(); i++)
  {
    ulong ticket = PositionGetTicket(i);
    if(ticket==0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
    if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
    string sym = PositionGetString(POSITION_SYMBOL);
    if(StringCompare(sym, _Symbol) != 0) continue;
    long type = PositionGetInteger(POSITION_TYPE);
    if(side==BUY_SIDE && type==POSITION_TYPE_BUY) cnt++;
    if(side==SELL_SIDE && type==POSITION_TYPE_SELL) cnt++;
  }
  return cnt;
}

//--- helper: refresh ticket and TP arrays for a side after opening
void RefreshSideState(int side)
{
  if(side==BUY_SIDE)
  {
    ArrayFree(ticketsBuy);
    ArrayFree(tpsBuy);
    int idx=0;
    for(int i=0; i<PositionsTotal(); i++)
    {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(StringCompare(sym, _Symbol) != 0) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(type!=POSITION_TYPE_BUY) continue;
      ArrayResize(ticketsBuy, idx+1);
      ArrayResize(tpsBuy, idx+1);
      ticketsBuy[idx] = ticket;
      tpsBuy[idx] = PositionGetDouble(POSITION_TP);
      idx++;
    }
    initialCountBuy = ArraySize(ticketsBuy);
    breakevenBuyApplied = false;
    // no tickets -> reset
    if(initialCountBuy==0) { ArrayFree(ticketsBuy); ArrayFree(tpsBuy); breakevenBuyApplied=false; initialCountBuy=0; }
  }
  else if(side==SELL_SIDE)
  {
    ArrayFree(ticketsSell);
    ArrayFree(tpsSell);
    int idx=0;
    for(int i=0; i<PositionsTotal(); i++)
    {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(StringCompare(sym, _Symbol) != 0) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(type!=POSITION_TYPE_SELL) continue;
      ArrayResize(ticketsSell, idx+1);
      ArrayResize(tpsSell, idx+1);
      ticketsSell[idx] = ticket;
      tpsSell[idx] = PositionGetDouble(POSITION_TP);
      idx++;
    }
    initialCountSell = ArraySize(ticketsSell);
    breakevenSellApplied = false;
    if(initialCountSell==0) { ArrayFree(ticketsSell); ArrayFree(tpsSell); breakevenSellApplied=false; initialCountSell=0; }
  }
}

//--- helper: find index of minimum-TP ticket in stored arrays
int FindMinTPTicketIndex(int side)
{
  if(side==BUY_SIDE)
  {
    int n = ArraySize(tpsBuy);
    if(n==0) return -1;
    int minIdx = 0;
    for(int i=1;i<n;i++)
    {
      if(tpsBuy[i] < tpsBuy[minIdx]) minIdx = i; // for BUY, smaller numeric TP = closer TP
    }
    return minIdx;
  }
  else
  {
    int n = ArraySize(tpsSell);
    if(n==0) return -1;
    int maxIdx = 0;
    for(int i=1;i<n;i++)
    {
      // for SELL, the TP numerically higher is the closest to entry (less distance)
      if(tpsSell[i] > tpsSell[maxIdx]) maxIdx = i;
    }
    return maxIdx;
  }
}

//--- helper: check if a previously-known ticket is missing from current positions
bool IsTicketStillOpen(ulong ticket)
{
  for(int i=0; i<PositionsTotal(); i++)
  {
    ulong t = PositionGetTicket(i);
    if(t==0) continue;
    if(!PositionSelectByTicket(t)) continue;
    if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
    string sym = PositionGetString(POSITION_SYMBOL);
    if(StringCompare(sym, _Symbol) != 0) continue;
    if(t==ticket) return true;
  }
  return false;
}

//--- when the min-TP order closes, move SL of remaining positions to breakeven
void CheckApplyBreakevenOnMinTPClosed()
{
  // BUY side
  if(initialCountBuy>0 && !breakevenBuyApplied)
  {
    // refresh current tickets and see which of stored tickets disappeared
    int missingCount = 0;
    int n = ArraySize(ticketsBuy);
    for(int i=0;i<n;i++)
    {
      if(!IsTicketStillOpen(ticketsBuy[i])) missingCount++;
    }
    // if any missing, check if the missing ticket was the min-TP one
    if(missingCount>0)
    {
      int minIdx = FindMinTPTicketIndex(BUY_SIDE);
      if(minIdx>=0)
      {
        ulong minTicket = ticketsBuy[minIdx];
        if(!IsTicketStillOpen(minTicket))
        {
          // apply breakeven to remaining BUY positions
          for(int i=0;i<PositionsTotal(); i++)
          {
            ulong t = PositionGetTicket(i);
            if(t==0) continue;
            if(!PositionSelectByTicket(t)) continue;
            if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
            string sym = PositionGetString(POSITION_SYMBOL);
            if(StringCompare(sym, _Symbol) != 0) continue;
            long type = PositionGetInteger(POSITION_TYPE);
            if(type!=POSITION_TYPE_BUY) continue;
            double entry = PositionGetDouble(POSITION_PRICE_OPEN);
            double tp = PositionGetDouble(POSITION_TP);
            // move SL to entry
            if(ModifyPositionSLTP(t, entry, tp))
              Print("Applied breakeven to BUY ticket ", t, " after min-TP closed.");
          }
          breakevenBuyApplied = true;
        }
      }
    }
    // if now no positions remain, reset state
    if(CountPositionsForSide(BUY_SIDE)==0) { ArrayFree(ticketsBuy); ArrayFree(tpsBuy); initialCountBuy=0; breakevenBuyApplied=false; }
  }

  // SELL side
  if(initialCountSell>0 && !breakevenSellApplied)
  {
    int missingCount = 0;
    int n = ArraySize(ticketsSell);
    for(int i=0;i<n;i++)
    {
      if(!IsTicketStillOpen(ticketsSell[i])) missingCount++;
    }
    if(missingCount>0)
    {
      int minIdx = FindMinTPTicketIndex(SELL_SIDE);
      if(minIdx>=0)
      {
        ulong minTicket = ticketsSell[minIdx];
        if(!IsTicketStillOpen(minTicket))
        {
          // apply breakeven to remaining SELL positions
          for(int i=0;i<PositionsTotal(); i++)
          {
            ulong t = PositionGetTicket(i);
            if(t==0) continue;
            if(!PositionSelectByTicket(t)) continue;
            if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
            string sym = PositionGetString(POSITION_SYMBOL);
            if(StringCompare(sym, _Symbol) != 0) continue;
            long type = PositionGetInteger(POSITION_TYPE);
            if(type!=POSITION_TYPE_SELL) continue;
            double entry = PositionGetDouble(POSITION_PRICE_OPEN);
            double tp = PositionGetDouble(POSITION_TP);
            // move SL to entry
            if(ModifyPositionSLTP(t, entry, tp))
              Print("Applied breakeven to SELL ticket ", t, " after min-TP closed.");
          }
          breakevenSellApplied = true;
        }
      }
    }
    if(CountPositionsForSide(SELL_SIDE)==0) { ArrayFree(ticketsSell); ArrayFree(tpsSell); initialCountSell=0; breakevenSellApplied=false; }
  }
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   string sym = _Symbol;
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)_Period; // use the chart's current timeframe

   int buyCount  = CountBuyConditionsTF(sym, tf);
   int sellCount = CountSellConditionsTF(sym, tf);

   bool readyBuy  = (buyCount  >= Threshold) && AllowLong;
   bool readySell = (sellCount >= Threshold) && AllowShort;

   double ask   = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(sym, SYMBOL_BID);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

   // If buy signal and there are open sell positions from this EA, close them first
   /*if(readyBuy)
   {
     if(HasPosition(SELL_SIDE))
     {
       Print("Buy signal: closing existing SELL positions before opening buys");
       ClosePositionsBySide(SELL_SIDE);
     }

     // only open if we don't already have buy positions
     if(!HasPosition(BUY_SIDE))
     {
       double sl_price, tp_price;
       CalculateDynamicSLTP(sym, BUY_SIDE, tf, ask, sl_price, tp_price, ATRMultiplier, TP_Multiple);
       double stopPoints = MathAbs(ask - sl_price) / point;

       double lot = CalculateLotByRisk(sym, stopPoints);
       if(lot > 0.0)
       {
         if(OpenTripleOrders(BUY_SIDE, lot, sl_price, tp_price))
         {
           // refresh state for buy side to track tickets & TPs
           RefreshSideState(BUY_SIDE);
           Print("Opened 3 BUY scaled orders totalLot=", DoubleToString(lot,2),
                 " SL=", DoubleToString(sl_price,(int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                 " baseTP=", DoubleToString(tp_price,(int)SymbolInfoInteger(sym, SYMBOL_DIGITS)));
         }
       }
     }
   }
*/
   // If sell signal and there are open buy positions from this EA, close them first
   if(readySell)
   {
     if(HasPosition(BUY_SIDE))
     {
       Print("Sell signal: closing existing BUY positions before opening sells");
       ClosePositionsBySide(BUY_SIDE);
     }

     if(!HasPosition(SELL_SIDE))
     {
       double sl_price_s, tp_price_s;
       CalculateDynamicSLTP(sym, SELL_SIDE, tf, bid, sl_price_s, tp_price_s, ATRMultiplier, TP_Multiple);
       double stopPoints_s = MathAbs(sl_price_s - bid) / point;

       double lot2 = CalculateLotByRisk(sym, stopPoints_s);
       if(lot2 > 0.0)
       {
         if(OpenTripleOrders(SELL_SIDE, lot2, sl_price_s, tp_price_s))
         {
           // refresh state for sell side to track tickets & TPs
           RefreshSideState(SELL_SIDE);
           Print("Opened 3 SELL scaled orders totalLot=", DoubleToString(lot2,2),
                 " SL=", DoubleToString(sl_price_s,(int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                 " baseTP=", DoubleToString(tp_price_s,(int)SymbolInfoInteger(sym, SYMBOL_DIGITS)));
         }
       }
     }
   }

   // Move SL to breakeven when 1R reached (existing behavior)
   CheckMoveToBreakEven();

   // New: apply breakeven when the order with minimum TP closes among the triple
   CheckApplyBreakevenOnMinTPClosed();
}

//+------------------------------------------------------------------+
int OnInit()
{
  Print("PrecisionMomentum_11conds (triple orders) initialized for ", _Symbol);
  return(INIT_SUCCEEDED);
}

int OnDeinit(const int reason)
{
  return 0;
}

//+------------------------------------------------------------------+
