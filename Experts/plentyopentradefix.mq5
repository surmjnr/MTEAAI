//+------------------------------------------------------------------+
//| PrecisionMomentum_triple_groups_final.mq5                        |
//| Full EA: triple-scaled groups, per-group breakeven, cooldown,    |
//| group cap, ATR/spread/HTF filters                                 |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
CTrade trade;

//---------------------- Inputs --------------------------------------
input double  RiskPercent             = 3.0;        // % equity risk per group (0 = use FixedLot)
input double  FixedLot                = 0.10;       // fallback lot if RiskPercent = 0
input double  MaxLot                  = 2.0;        // maximum lot
input double  ATRMultiplier           = 1.5;        // ATR * multiplier for SL buffer
input int     ATRPeriod               = 14;         // ATR period
input double  TP_Multiple             = 2.0;        // base TP = TP_Multiple * SL distance
input int     Threshold               = 1;          // condition threshold (sample conds)
input int     MagicNumber             = 20251103;   // EA magic
input int     SlippagePoints          = 6;          // slippage in points
input bool    MoveToBreakEven         = true;       // per-position 1R -> move to breakeven
input bool    AllowLong               = true;
input bool    AllowShort              = true;

//--- New management inputs (Option B)
input int     MaxGroupsPerSide        = 3;          // maximum triple groups per side
input int     SignalCooldownSeconds   = 60;         // seconds between open groups on same side

//--- Filters
input bool    RequireHTF              = true;       // require higher-timeframe EMA confirm
input ENUM_TIMEFRAMES ConfirmTF       = PERIOD_H1;  // HTF for confirmation
input double  MinATRPoints            = 0.0;        // min ATR in points (0 disables)
input double  MaxSpreadPoints         = 0.0;        // max spread allowed in points (0 disables)

//---------------------- Globals -------------------------------------
#define BUY_SIDE  1
#define SELL_SIDE -1

// group structure
struct TripleGroup
{
  ulong   groupId;
  int     side;                  // BUY_SIDE / SELL_SIDE
  int     nTickets;              // actual number of tickets currently in group (<=3)
  ulong   tickets[3];
  double  tps[3];
  double  entryPrices[3];
  double  lots[3];
  bool    breakevenApplied;
  datetime openTime;
  string  comment;
};

// groups dynamic array
TripleGroup groups[];
ulong nextGroupId = 1;

// cooldown trackers
datetime lastBuySignalTime = 0;
datetime lastSellSignalTime = 0;

//---------------------- Utility functions ---------------------------

double EMA(string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
  double buf[];
  int handle = iMA(sym, tf, period, 0, MODE_EMA, PRICE_CLOSE);
  if(handle == INVALID_HANDLE) return 0.0;
  if(CopyBuffer(handle, 0, shift, 1, buf) <= 0) { IndicatorRelease(handle); return 0.0; }
  IndicatorRelease(handle);
  return buf[0];
}

void EMA_values(string sym, ENUM_TIMEFRAMES tf, int pFast, int pSlow, double &fastNow, double &slowNow, double &fastPrev, double &slowPrev)
{
  fastNow  = EMA(sym, tf, pFast, 0);
  slowNow  = EMA(sym, tf, pSlow, 0);
  fastPrev = EMA(sym, tf, pFast, 1);
  slowPrev = EMA(sym, tf, pSlow, 1);
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

// sample buy condition (EMA 9/21 crossover on current TF, using closed bar for stability)
int CountBuyConditionsTF(string sym, ENUM_TIMEFRAMES tf)
{
  int met = 0;
  double fastNow, slowNow, fastPrev, slowPrev;
  EMA_values(sym, tf, 9, 21, fastNow, slowNow, fastPrev, slowPrev);
  // use previous closed bar crossover to avoid flicker
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

// calculate lot per group based on RiskPercent and stop loss in points
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

// check if a ticket is still open (owned by our EA and symbol)
bool IsTicketStillOpen(ulong ticket)
{
  for(int i=0;i<PositionsTotal();i++)
  {
    ulong t = PositionGetTicket(i);
    if(t==ticket)
    {
      if(!PositionSelectByTicket(t)) return false;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) return false;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(StringCompare(sym, _Symbol) != 0) return false;
      return true;
    }
  }
  return false;
}

// Modify SL/TP for position
bool ModifyPositionSLTP(ulong ticket, double sl, double tp)
{
  if(ticket==0) return false;
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  bool ok = trade.PositionModify(ticket, sl, tp);
  if(!ok) Print("Modify failed for ticket ", ticket, ": ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
  return ok;
}

// Open market order with comment
bool OpenMarketOrderWithComment(int side, double lot, double slPrice, double tpPrice, const string comment)
{
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  bool res=false;
  if(side==BUY_SIDE)
    res = trade.Buy(lot, NULL, 0.0, slPrice, tpPrice, comment);
  else
    res = trade.Sell(lot, NULL, 0.0, slPrice, tpPrice, comment);
  if(!res) Print("Order failed (", comment, ") code=", trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription());
  return res;
}

// Calculate dynamic SL/TP
void CalculateDynamicSLTP(string sym, int side, ENUM_TIMEFRAMES tf,
                          double entryPrice, double &slPrice, double &tpPrice,
                          double atrMult, double rewardR)
{
   int lookback = 5;
   double atr = ATRv(sym, tf, 14, 0);
   if (atr <= 0.0) atr = SymbolInfoDouble(sym, SYMBOL_POINT) * 100;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double recentHigh = iHigh(sym, tf, iHighest(sym, tf, MODE_HIGH, lookback, 1));
   double recentLow  = iLow(sym, tf, iLowest(sym, tf, MODE_LOW, lookback, 1));
   double buffer = atrMult * atr;

   if (side == BUY_SIDE)
   {
      slPrice = MathMin(recentLow, entryPrice - buffer);
      tpPrice = entryPrice + (entryPrice - slPrice) * rewardR;
   }
   else
   {
      slPrice = MathMax(recentHigh, entryPrice + buffer);
      tpPrice = entryPrice - (slPrice - entryPrice) * rewardR;
   }
}

// Open triple orders with comment (33.3%, 66.6%, 100% scaling)
bool OpenTripleOrdersWithComment(int side, double totalLot, double slPrice, double baseTpPrice, const string comment)
{
  double entry = (side==BUY_SIDE) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

  double fullTpPoints = MathAbs(baseTpPrice - entry) / point;
  if(fullTpPoints <= 0) { Print("Invalid TP distance"); return false; }

  double tpPoints_full = fullTpPoints;
  double tpPoints_one  = fullTpPoints / 3.0;         // 33.3%
  double tpPoints_two  = fullTpPoints * 2.0 / 3.0;   // 66.6%

  double tp_full = (side==BUY_SIDE) ? (entry + tpPoints_full * point) : (entry - tpPoints_full * point);
  double tp_one  = (side==BUY_SIDE) ? (entry + tpPoints_one  * point) : (entry - tpPoints_one  * point);
  double tp_two  = (side==BUY_SIDE) ? (entry + tpPoints_two  * point) : (entry - tpPoints_two  * point);

  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

  if(totalLot < minLot) totalLot = minLot;
  if(totalLot > maxLot) totalLot = maxLot;

  double part = MathFloor((totalLot / 3.0) / step) * step;
  if(part < step) part = step;

  double lot1 = part;
  double lot2 = part;
  double lot3 = part;

  double used = lot1 + lot2 + lot3;
  double leftover = MathFloor(((totalLot - used) / step)) * step;
  if(leftover < 0) leftover = 0;
  lot1 = lot1 + leftover;

  lot1 = MathMin(MathMax(lot1, minLot), maxLot);
  lot2 = MathMin(MathMax(lot2, minLot), maxLot);
  lot3 = MathMin(MathMax(lot3, minLot), maxLot);

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  bool ok1 = OpenMarketOrderWithComment(side, lot1, slPrice, tp_full, comment);
  bool ok2 = OpenMarketOrderWithComment(side, lot2, slPrice, tp_one, comment);
  bool ok3 = OpenMarketOrderWithComment(side, lot3, slPrice, tp_two, comment);

  return (ok1 || ok2 || ok3);
}

// Create group by scanning positions with the comment and assign provided gid
bool CreateTripleGroupFromComment(int side, const string comment, ulong gid)
{
  TripleGroup grp;
  ArrayFill(grp.tickets, 0, 3, 0);
  ArrayFill(grp.tps, 0, 3, 0.0);
  ArrayFill(grp.entryPrices, 0, 3, 0.0);
  ArrayFill(grp.lots, 0, 3, 0.0);

  grp.groupId = gid;
  grp.side = side;
  grp.nTickets = 0;
  grp.breakevenApplied = false;
  grp.openTime = TimeCurrent();
  grp.comment = comment;

  for(int i=0;i<PositionsTotal();i++)
  {
    ulong ticket = PositionGetTicket(i);
    if(ticket==0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
    if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
    string sym = PositionGetString(POSITION_SYMBOL);
    if(StringCompare(sym, _Symbol) != 0) continue;
    string posComment = PositionGetString(POSITION_COMMENT);
    if(StringCompare(posComment, comment) != 0) continue;
    long type = PositionGetInteger(POSITION_TYPE);
    if((side==BUY_SIDE && type!=POSITION_TYPE_BUY) || (side==SELL_SIDE && type!=POSITION_TYPE_SELL)) continue;

    int idx = grp.nTickets;
    if(idx < 3)
    {
      grp.tickets[idx] = ticket;
      grp.tps[idx] = PositionGetDouble(POSITION_TP);
      grp.entryPrices[idx] = PositionGetDouble(POSITION_PRICE_OPEN);
      grp.lots[idx] = PositionGetDouble(POSITION_VOLUME);
      grp.nTickets++;
    }
  }

  if(grp.nTickets==0) return false;

  int oldSize = ArraySize(groups);
  ArrayResize(groups, oldSize+1);
  groups[oldSize] = grp;
  PrintFormat("Created group id=%I64u side=%s tickets=%d comment=%s", grp.groupId, (grp.side==BUY_SIDE?"BUY":"SELL"), grp.nTickets, comment);
  return true;
}

// Register group after open: try immediate scans a few times
void RegisterGroupAfterOpen(int side, const string comment, ulong gid)
{
  // attempt immediate creation a few times
  for(int attempt=0; attempt<3; attempt++)
  {
    if(CreateTripleGroupFromComment(side, comment, gid)) return;
    Sleep(50);
  }
  PrintFormat("Warning: group with comment=%s gid=%I64u not found immediately; OnTradeTransaction will register later.", comment, gid);
}

// Find index of min-TP in a group
int FindMinTPTicketIndexForGroup(const TripleGroup &g)
{
  if(g.nTickets==0) return -1;
  int idx = 0;
  if(g.side==BUY_SIDE)
  {
    for(int i=1;i<g.nTickets;i++)
      if(g.tps[i] < g.tps[idx]) idx = i;
  }
  else
  {
    for(int i=1;i<g.nTickets;i++)
      if(g.tps[i] > g.tps[idx]) idx = i;
  }
  return idx;
}

// OnTradeTransaction: handle closed tickets and group breakeven
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
  // iterate from end to start because we may remove groups
  for(int gi=ArraySize(groups)-1; gi>=0; gi--)
  {
    TripleGroup g = groups[gi]; // local copy
    bool closedFound = false;

    // build array of whether each known ticket is still open
    bool stillOpen[3];
    for(int i=0;i<g.nTickets;i++) stillOpen[i] = IsTicketStillOpen(g.tickets[i]);

    int closedIdx = -1;
    for(int i=0;i<g.nTickets;i++)
    {
      if(!stillOpen[i]) { closedIdx = i; break; }
    }

    if(closedIdx >= 0)
    {
      closedFound = true;
      ulong closedTicket = g.tickets[closedIdx];
      PrintFormat("Detected closed ticket %I64u in group %I64u (side=%s)", closedTicket, g.groupId, (g.side==BUY_SIDE?"BUY":"SELL"));

      int minIdx = FindMinTPTicketIndexForGroup(g);
      if(minIdx >= 0)
      {
        ulong minTicket = g.tickets[minIdx];
        if(minTicket == closedTicket && !g.breakevenApplied)
        {
          // apply breakeven to remaining open tickets in this group
          for(int j=0;j<g.nTickets;j++)
          {
            if(stillOpen[j])
            {
              ulong t = g.tickets[j];
              double entry = g.entryPrices[j];
              if(entry <= 0.0)
              {
                if(PositionSelectByTicket(t)) entry = PositionGetDouble(POSITION_PRICE_OPEN);
              }
              double tp = g.tps[j];
              if(entry > 0.0)
              {
                if(ModifyPositionSLTP(t, entry, tp))
                  PrintFormat("Applied group breakeven to ticket %I64u (group %I64u).", t, g.groupId);
              }
            }
          }
          g.breakevenApplied = true;
        }
      }

      // compact group's arrays removing closed tickets
      int newCount = 0;
      ulong newTickets[3];
      double newTps[3];
      double newEntries[3];
      double newLots[3];
      for(int k=0;k<g.nTickets;k++)
      {
        if(stillOpen[k])
        {
          newTickets[newCount] = g.tickets[k];
          newTps[newCount] = g.tps[k];
          newEntries[newCount] = g.entryPrices[k];
          newLots[newCount] = g.lots[k];
          newCount++;
        }
      }

      g.nTickets = newCount;
      for(int k=0;k<3;k++)
      {
        g.tickets[k] = (k<newCount) ? newTickets[k] : 0;
        g.tps[k] = (k<newCount) ? newTps[k] : 0.0;
        g.entryPrices[k] = (k<newCount) ? newEntries[k] : 0.0;
        g.lots[k] = (k<newCount) ? newLots[k] : 0.0;
      }

      if(g.nTickets == 0)
      {
        PrintFormat("All tickets closed for group %I64u. Removing group.", g.groupId);
        // remove groups[gi]
        int oldSize = ArraySize(groups);
        for(int r=gi; r<oldSize-1; r++) groups[r] = groups[r+1];
        ArrayResize(groups, oldSize-1);
      }
      else
      {
        // write back updated group
        groups[gi] = g;
      }
    } // if closedIdx
  } // for groups
}

// Count active groups for a side (count groups[] entries)
int CountActiveGroups(int side)
{
  int cnt=0;
  for(int i=0;i<ArraySize(groups);i++) if(groups[i].side==side) cnt++;
  return cnt;
}

// Per-position MoveToBreakEven (1R reached) - unchanged logic
void CheckMoveToBreakEven()
{
  if(!MoveToBreakEven) return;
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

// Sideways and safety filters (ATR, spread, HTF)
bool PassesSidewaysFilters(int side, ENUM_TIMEFRAMES tf)
{
  double spreadPoints = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  if(MaxSpreadPoints > 0.0 && spreadPoints > MaxSpreadPoints)
  {
    PrintFormat("Skipped open: spread %.1f > MaxSpread %.1f points", spreadPoints, MaxSpreadPoints);
    return false;
  }

  if(MinATRPoints > 0.0)
  {
    double atr = ATRv(_Symbol, tf, ATRPeriod, 0);
    double atrPoints = atr / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if(atrPoints < MinATRPoints)
    {
      PrintFormat("Skipped open: ATR %.1f < MinATR %.1f (points)", atrPoints, MinATRPoints);
      return false;
    }
  }

  if(RequireHTF)
  {
    double fastNow, slowNow, fastPrev, slowPrev;
    EMA_values(_Symbol, ConfirmTF, 9, 21, fastNow, slowNow, fastPrev, slowPrev);
    if(side==BUY_SIDE)
    {
      if(!(fastPrev <= slowPrev && fastNow > slowNow))
      {
        Print("Skipped BUY: HTF EMA condition not met");
        return false;
      }
    }
    else
    {
      if(!(fastPrev >= slowPrev && fastNow < slowNow))
      {
        Print("Skipped SELL: HTF EMA condition not met");
        return false;
      }
    }
  }

  return true;
}

// Main OnTick: evaluate signals, apply cooldown + group cap, open groups
void OnTick()
{
  ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)_Period;
  string sym = _Symbol;
  double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
  double bid = SymbolInfoDouble(sym, SYMBOL_BID);
  double point = SymbolInfoDouble(sym, SYMBOL_POINT);

  // per-position breakeven
  CheckMoveToBreakEven();

  // signals (sample)
  int buyCount = CountBuyConditionsTF(sym, tf);
  int sellCount = CountSellConditionsTF(sym, tf);
  bool readyBuy = (buyCount >= Threshold) && AllowLong;
  bool readySell = (sellCount >= Threshold) && AllowShort;

  // BUY handling
  if(readyBuy)
  {
    int activeBuyGroups = CountActiveGroups(BUY_SIDE);
    bool cooldownOK = (TimeCurrent() - lastBuySignalTime >= SignalCooldownSeconds);
    if(activeBuyGroups < MaxGroupsPerSide && cooldownOK)
    {
      if(PassesSidewaysFilters(BUY_SIDE, tf))
      {
        // compute SL/TP & lot
        double sl_price, tp_price;
        CalculateDynamicSLTP(sym, BUY_SIDE, tf, ask, sl_price, tp_price, ATRMultiplier, TP_Multiple);
        double stopPoints = MathAbs(ask - sl_price) / point;
        double lot = CalculateLotByRisk(sym, stopPoints);
        if(lot > 0.0)
        {
          // assign group id and comment
          ulong gid = nextGroupId++;
          string comment = StringFormat("PM_11_BUY_g%I64u", gid);
          bool opened = OpenTripleOrdersWithComment(BUY_SIDE, lot, sl_price, tp_price, comment);
          if(opened)
          {
            RegisterGroupAfterOpen(BUY_SIDE, comment, gid);
            lastBuySignalTime = TimeCurrent();
            PrintFormat("Requested BUY triple group gid=%I64u totalLot=%.2f SL=%.5f baseTP=%.5f", gid, lot, sl_price, tp_price);
          }
        }
      }
    }
    else
    {
      if(!cooldownOK)
      {
        int left = SignalCooldownSeconds - (int)(TimeCurrent() - lastBuySignalTime);
        if(left<0) left=0;
        PrintFormat("BUY signal on cooldown: %d sec left", left);
      }
      if(activeBuyGroups >= MaxGroupsPerSide)
      {
        PrintFormat("BUY signal ignored: active buy groups %d >= MaxGroupsPerSide %d", activeBuyGroups, MaxGroupsPerSide);
      }
    }
  }

  // SELL handling
  if(readySell)
  {
    int activeSellGroups = CountActiveGroups(SELL_SIDE);
    bool cooldownOK = (TimeCurrent() - lastSellSignalTime >= SignalCooldownSeconds);
    if(activeSellGroups < MaxGroupsPerSide && cooldownOK)
    {
      if(PassesSidewaysFilters(SELL_SIDE, tf))
      {
        double sl_price_s, tp_price_s;
        CalculateDynamicSLTP(sym, SELL_SIDE, tf, bid, sl_price_s, tp_price_s, ATRMultiplier, TP_Multiple);
        double stopPoints_s = MathAbs(sl_price_s - bid) / point;
        double lot2 = CalculateLotByRisk(sym, stopPoints_s);
        if(lot2 > 0.0)
        {
          ulong gid = nextGroupId++;
          string comment = StringFormat("PM_11_SELL_g%I64u", gid);
          bool opened = OpenTripleOrdersWithComment(SELL_SIDE, lot2, sl_price_s, tp_price_s, comment);
          if(opened)
          {
            RegisterGroupAfterOpen(SELL_SIDE, comment, gid);
            lastSellSignalTime = TimeCurrent();
            PrintFormat("Requested SELL triple group gid=%I64u totalLot=%.2f SL=%.5f baseTP=%.5f", gid, lot2, sl_price_s, tp_price_s);
          }
        }
      }
    }
    else
    {
      if(!cooldownOK)
      {
        int left = SignalCooldownSeconds - (int)(TimeCurrent() - lastSellSignalTime);
        if(left<0) left=0;
        PrintFormat("SELL signal on cooldown: %d sec left", left);
      }
      if(activeSellGroups >= MaxGroupsPerSide)
      {
        PrintFormat("SELL signal ignored: active sell groups %d >= MaxGroupsPerSide %d", activeSellGroups, MaxGroupsPerSide);
      }
    }
  }
}

// Init / Deinit
int OnInit()
{
  ArrayResize(groups, 0);
  Print("PrecisionMomentum_triple_groups_final initialized for ", _Symbol);
  return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
  // no special clean
}
//+------------------------------------------------------------------+
