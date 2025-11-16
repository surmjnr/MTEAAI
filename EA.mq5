//+------------------------------------------------------------------+
// AI_Trader_EA_OptionD.mq5
// Option D: replay missing candles, no trades while offline, weekly /train
//+------------------------------------------------------------------+
#property strict
#property version "1.30"
#property description "AI-driven EA Option D: replay missing candles; live memory; weekly train"

input string   AiServerPredictURL = "http://192.168.12.38:5000/predict";
input string   AiServerIngestURL  = "http://192.168.12.38:5000/ingest";   // batch/replay ingestion
input string   AiServerTrainURL   = "http://192.168.12.38:5000/train";
input string   SymbolToTrade      = "EURUSD";
input ENUM_TIMEFRAMES TimeframeToWatch = PERIOD_H1;
input double   LotSizeDefault     = 0.10;
input double   StopLossPips       = 30.0;
input double   TakeProfitPips     = 60.0;
input int      RequestTimeout     = 5000;
input int      BarsToSendOnFirstSync = 1000; // initial sync if no last_sent known
input int      LiveMemorySize     = 1000;    // Option B confirmed
input int      RetrainWeekday     = 5;       // Friday
input int      RetrainHour        = 23;      // 23:00 broker/server time

// Global variable name pattern to persist last sent bar across restarts
string gv_prefix = "AI_LastSentBar_";

datetime lastCheckedBar = 0;
string   g_symbol;
datetime lastWeeklyTrainSent = 0;
bool     in_replay = false;   // true while replaying missing candles (no trades)

//----------------------------------------------------------------
int OnInit()
  {
   g_symbol = SymbolToTrade;
   PrintFormat("AI_Trader_EA OptionD initialized. Symbol=%s TF=%s PredictURL=%s IngestURL=%s TrainURL=%s",
               g_symbol, EnumToString(TimeframeToWatch), AiServerPredictURL, AiServerIngestURL, AiServerTrainURL);
   // read persisted last sent bar global variable (per symbol/timeframe)
   string gv_name = gv_prefix + g_symbol + "_" + IntegerToString(TimeframeToWatch);
   if(!GlobalVariableCheck(gv_name))
     {
      GlobalVariableSet(gv_name, 0.0);
      Print("No previous last-sent bar found; starting fresh.");
     }
   else
     {
      double v = GlobalVariableGet(gv_name);
      if(v > 0) PrintFormat("Recovered lastSentBar = %s", TimeToString((datetime)v, TIME_DATE|TIME_MINUTES));
     }
   return(INIT_SUCCEEDED);
  }
//----------------------------------------------------------------
void OnDeinit(const int reason)
  {
   Print("AI_Trader_EA deinitialized.");
  }
//----------------------------------------------------------------
void OnTick()
  {
   // get last closed bar time for the watched TF (index 1 = last closed)
   datetime curBarTime = iTime(g_symbol, TimeframeToWatch, 1);
   if(curBarTime == 0) return;
   if(curBarTime == lastCheckedBar) return;
   lastCheckedBar = curBarTime;

   // Weekly training trigger (will not interfere with replay/trading)
   TryWeeklyTrainingTrigger();

   // Step 1: ensure live sequence: replay any missing candles to server
   bool seq_ok = EnsureSequenceAndReplay(curBarTime);
   if(!seq_ok)
     {
      // server not available or replay failed; do not trade
      Print("Sequence incomplete or server offline — skipping trading for this bar.");
      return;
     }

   // Only after sequence is confirmed we can do a predict + trade
   // Ensure no open position (one position per pair)
   if(HasPositionForSymbol(g_symbol))
     {
      PrintFormat("Position already open for %s", g_symbol);
      return;
     }

   // Build payload for prediction (use last closed bar — index 1)
   double open  = iOpen(g_symbol, TimeframeToWatch, 1);
   double high  = iHigh(g_symbol, TimeframeToWatch, 1);
   double low   = iLow(g_symbol, TimeframeToWatch, 1);
   double close = iClose(g_symbol, TimeframeToWatch, 1);
   long   vol   = (long)iVolume(g_symbol, TimeframeToWatch, 1);

   if(open == 0 && high == 0 && low == 0 && close == 0)
     {
      Print("No valid candle data for prediction.");
      return;
     }

   string payload = StringFormat(
      "{\"Symbol\":\"%s\",\"Timeframe\":\"%s\",\"Open\":%.5f,\"High\":%.5f,\"Low\":%.5f,\"Close\":%.5f,\"Volume\":%d}",
      g_symbol, EnumToString(TimeframeToWatch), open, high, low, close, vol
   );

   // POST to /predict; on success server will store candle to live memory as well
   string response = SendJsonPost(AiServerPredictURL, payload);
   if(StringLen(response) == 0)
     {
      Print("Predict request failed or empty response; not trading.");
      return;
     }

   string ai_up = StringToUpperHelper(response);
   double slPips = StopLossPips;
   double tpPips = TakeProfitPips;
   double tmpSL = ExtractNumberFromJson(ai_up, "STOP_LOSS_PIPS");
   double tmpTP = ExtractNumberFromJson(ai_up, "TAKE_PROFIT_PIPS");
   if(tmpSL > 0) slPips = tmpSL;
   if(tmpTP > 0) tpPips = tmpTP;

   if(StringFind(ai_up, "BUY") >= 0)
     {
      bool ok = OpenTradeBuy(g_symbol, LotSizeDefault, slPips, tpPips);
      if(ok) Print("AI BUY Success");
      else   Print("AI BUY Failed");
     }
   else if(StringFind(ai_up, "SELL") >= 0)
     {
      bool ok = OpenTradeSell(g_symbol, LotSizeDefault, slPips, tpPips);
      if(ok) Print("AI SELL Success");
      else   Print("AI SELL Failed");
     }
   else
     {
      Print("AI returned no actionable signal. Response: ", response);
     }
  }
//----------------------------------------------------------------
// Ensure sequence: replay missing candles (if any) to server's /ingest endpoint.
// Returns true only if either no missing candles or all missing sent successfully.
bool EnsureSequenceAndReplay(datetime curBarTime)
  {
   string gv_name = gv_prefix + g_symbol + "_" + IntegerToString(TimeframeToWatch);
   double last_sent_val = GlobalVariableGet(gv_name);
   datetime last_sent = (datetime)last_sent_val;

   // If no last sent, perform initial sync of BarsToSendOnFirstSync recent bars
   if((datetime)last_sent == 0)
     {
      Print("No last_sent recorded — performing initial sync (recent bars).");
      bool ok = SendRecentBarsAsReplay(BarsToSendOnFirstSync);
      if(ok)
        {
         // record last sent as curBarTime
         GlobalVariableSet(gv_name, (double)curBarTime);
         PrintFormat("Initial sync done. last_sent set to %s", TimeToString(curBarTime, TIME_DATE|TIME_MINUTES));
         return true;
        }
      else
        {
         Print("Initial sync failed.");
         return false;
        }
     }

   // If last_sent equals curBarTime already, we're in sync
   if(last_sent == curBarTime)
     {
      return true;
     }

   // Find the bar shift for last_sent
   int lastShift = iBarShift(g_symbol, TimeframeToWatch, last_sent, true); // exact match required
   if(lastShift == -1)
     {
      // last_sent not found (data rollover or old) -> send last BarsToSendOnFirstSync bars as replay
      Print("last_sent not found in history. Performing a resync of recent bars.");
      bool ok = SendRecentBarsAsReplay(BarsToSendOnFirstSync);
      if(ok)
        {
         GlobalVariableSet(gv_name, (double)curBarTime);
         return true;
        }
      else
        {
         return false;
        }
     }

   // Now lastShift >= 1 (1 is last closed bar). If lastShift == 1 => we already sent the most recent closed bar
   if(lastShift <= 1)
     {
      // last_sent is the previous closed bar or more recent -> nothing missing
      GlobalVariableSet(gv_name, (double)curBarTime);
      return true;
     }

   // There are missing bars: they are shifts lastShift-1, lastShift-2, ..., 1 (older -> newer)
   int total = MathMin(lastShift-1, BarsToSendOnFirstSync); // prevent huge loops: cap to BarsToSendOnFirstSync
   PrintFormat("Missing %d bars to replay (shifts %d down to 1).", lastShift-1, lastShift-1);
   // Build JSON array with chronological order (oldest first)
   string json = StringFormat("{\"Symbol\":\"%s\",\"Timeframe\":\"%s\",\"Bars\":[", g_symbol, EnumToString(TimeframeToWatch));
   bool first = true;
   for(int s = lastShift - 1; s >= 1; s--)
     {
      if(!first) json += ",";
      datetime t = iTime(g_symbol, TimeframeToWatch, s);
      double o = iOpen(g_symbol, TimeframeToWatch, s);
      double h = iHigh(g_symbol, TimeframeToWatch, s);
      double l = iLow(g_symbol, TimeframeToWatch, s);
      double c = iClose(g_symbol, TimeframeToWatch, s);
      long v   = (long)iVolume(g_symbol, TimeframeToWatch, s);
      json += StringFormat("{\"t\":%I64d,\"o\":%.5f,\"h\":%.5f,\"l\":%.5f,\"c\":%.5f,\"v\":%d}",
                           t, o, h, l, c, v);
      first = false;
     }
   json += "]}";

   // Send the batch to /ingest
   bool sent = SendJsonPostBool(AiServerIngestURL, json);
   if(!sent)
     {
      Print("Replay ingest failed; server may be offline.");
      return false;
     }

   // If ingest success, update last_sent to curBarTime and return true
   string gv = gv_name;
   GlobalVariableSet(gv, (double)curBarTime);
   PrintFormat("Replay successful. Updated last_sent to %s", TimeToString(curBarTime, TIME_DATE|TIME_MINUTES));
   return true;
  }
//----------------------------------------------------------------
// Send recent N bars as replay (used when last_sent missing or initial sync)
bool SendRecentBarsAsReplay(int barsToCollect)
  {
   int total = iBars(g_symbol, TimeframeToWatch);
   if(total <= 1)
     {
      Print("Not enough bars for replay.");
      return false;
     }
   int count = MathMin(total - 1, barsToCollect);
   string json = StringFormat("{\"Symbol\":\"%s\",\"Timeframe\":\"%s\",\"Bars\":[", g_symbol, EnumToString(TimeframeToWatch));
   bool first = true;
   // build chronological older -> newer: start from shift=count down to 1
   for(int s = count; s >= 1; s--)
     {
      if(!first) json += ",";
      datetime t = iTime(g_symbol, TimeframeToWatch, s);
      double o = iOpen(g_symbol, TimeframeToWatch, s);
      double h = iHigh(g_symbol, TimeframeToWatch, s);
      double l = iLow(g_symbol, TimeframeToWatch, s);
      double c = iClose(g_symbol, TimeframeToWatch, s);
      long v   = (long)iVolume(g_symbol, TimeframeToWatch, s);
      json += StringFormat("{\"t\":%I64d,\"o\":%.5f,\"h\":%.5f,\"l\":%.5f,\"c\":%.5f,\"v\":%d}",
                           t, o, h, l, c, v);
      first = false;
     }
   json += "]}";
   bool sent = SendJsonPostBool(AiServerIngestURL, json);
   if(!sent) { Print("SendRecentBarsAsReplay: ingest failed."); return false; }
   return true;
  }
//----------------------------------------------------------------
// Simple helper: send POST JSON and return response text (or empty)
string SendJsonPost(const string url, const string payload)
  {
   string headers = "Content-Type: application/json; charset=utf-8\r\n";
   uchar post[];
   int wrote = StringToCharArray(payload, post, 0, WHOLE_ARRAY, CP_UTF8);
   if(wrote <= 0) { Print("SendJsonPost: StringToCharArray failed."); return ""; }
   if(ArraySize(post) > 0 && post[ArraySize(post)-1] == 0) ArrayResize(post, ArraySize(post)-1);
   uchar result[];
   string result_headers = "";
   ResetLastError();
   int status = WebRequest("POST", url, headers, RequestTimeout, post, result, result_headers);
   if(status == -1)
     {
      int err = GetLastError();
      PrintFormat("WebRequest failed (Error %d) for URL %s", err, url);
      return "";
     }
   string text = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(status != 200)
     {
      PrintFormat("HTTP %d from %s: %s", status, url, text);
      return "";
     }
   return text;
  }
//----------------------------------------------------------------
// Same but return bool success (no content needed)
bool SendJsonPostBool(const string url, const string payload)
  {
   string res = SendJsonPost(url, payload);
   return StringLen(res) > 0;
  }
//----------------------------------------------------------------
// Weekly training trigger: once per week on RetrainWeekday and RetrainHour
void TryWeeklyTrainingTrigger()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int dow = dt.day_of_week;   // 0=Sun ... 5=Fri
   int hr  = dt.hour;
   if(dow != RetrainWeekday || hr < RetrainHour) return;
   // guard: lastWeeklyTrainSent persisted for safety
   if((long)(TimeCurrent() - lastWeeklyTrainSent) < (7*24*3600))
     {
      // already sent recently (within 7 days)
      return;
     }
   Print("Weekly training condition met — collecting bars and sending to /train...");
   // Collect BarsToSendOnFirstSync recent bars in CSV-like JSON
   int total = iBars(g_symbol, TimeframeToWatch);
   int count = MathMin(total - 1, BarsToSendOnFirstSync);
   if(count <= 1) { Print("Not enough bars to send for training."); return; }
   string json = StringFormat("{\"Symbol\":\"%s\",\"Timeframe\":\"%s\",\"Bars\":[", g_symbol, EnumToString(TimeframeToWatch));
   bool first = true;
   for(int s = count; s >= 1; s--)
     {
      if(!first) json += ",";
      datetime t = iTime(g_symbol, TimeframeToWatch, s);
      double o = iOpen(g_symbol, TimeframeToWatch, s);
      double h = iHigh(g_symbol, TimeframeToWatch, s);
      double l = iLow(g_symbol, TimeframeToWatch, s);
      double c = iClose(g_symbol, TimeframeToWatch, s);
      long v   = (long)iVolume(g_symbol, TimeframeToWatch, s);
      json += StringFormat("{\"t\":%I64d,\"o\":%.5f,\"h\":%.5f,\"l\":%.5f,\"c\":%.5f,\"v\":%d}",
                           t, o, h, l, c, v);
      first = false;
     }
   json += "]}";
   bool ok = SendJsonPostBool(AiServerTrainURL, json);
   if(ok)
     {
      lastWeeklyTrainSent = TimeCurrent();
      Print("Weekly training data sent successfully.");
     }
   else
     {
      Print("Failed to send weekly training data.");
     }
  }
//----------------------------------------------------------------
// Standard helper functions (positions, trades, etc.) - copy from previous working EA
bool HasPositionForSymbol(const string symbol)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionSelectByTicket(ticket))
           {
            if(PositionGetString(POSITION_SYMBOL) == symbol)
               return true;
           }
        }
     }
   return false;
  }
// Extract number from JSON-like uppercase text
double ExtractNumberFromJson(const string text_upper, const string key_upper)
  {
   string pattern = StringFormat("\"%s\":", key_upper);
   int pos = StringFind(text_upper, pattern);
   if(pos < 0)
     {
      pattern = StringFormat("%s:", key_upper);
      pos = StringFind(text_upper, pattern);
      if(pos < 0) return 0.0;
     }
   int start = pos + StringLen(pattern);
   string numstr = "";
   for(int i = start; i < StringLen(text_upper); i++)
     {
      ushort c = StringGetCharacter(text_upper, i);
      if((c >= '0' && c <= '9') || c == '.' || c == '-')
         numstr += CharToString((uchar)c);
      else
        {
         if(StringLen(numstr) > 0) break;
        }
     }
   if(StringLen(numstr) == 0) return 0.0;
   return StringToDouble(numstr);
  }
// Pips to points
double PipsToPoints(const string symbol, double pips)
  {
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return pips * point * 10.0;
   else
      return pips * point;
  }
// Trading functions
bool OpenTradeBuy(const string sym, double lots, double slPips, double tpPips)
  {
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double sl = NormalizeDouble(ask - PipsToPoints(sym, slPips), digits);
   double tp = NormalizeDouble(ask + PipsToPoints(sym, tpPips), digits);
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action      = TRADE_ACTION_DEAL;
   request.symbol      = sym;
   request.volume      = lots;
   request.type        = ORDER_TYPE_BUY;
   request.price       = ask;
   request.sl          = sl;
   request.tp          = tp;
   request.deviation   = 10;
   request.magic       = (ulong)123456;
   request.comment     = "AI BUY";
   ENUM_ORDER_TYPE_FILLING filling = GetFillingMode(sym);
   request.type_filling= filling;
   request.type_time   = ORDER_TIME_GTC;
   bool sent = OrderSend(request, result);
   if(!sent || result.retcode != TRADE_RETCODE_DONE)
     {
      PrintFormat("OrderSend failed: retcode=%d comment=%s", result.retcode, result.comment);
      return false;
     }
   PrintFormat("BUY opened: deal=%I64d @ %.5f SL=%.5f TP=%.5f",
            result.deal, ask, sl, tp);
   return true;
  }
bool OpenTradeSell(const string sym, double lots, double slPips, double tpPips)
  {
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double sl = NormalizeDouble(bid + PipsToPoints(sym, slPips), digits);
   double tp = NormalizeDouble(bid - PipsToPoints(sym, tpPips), digits);
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action      = TRADE_ACTION_DEAL;
   request.symbol      = sym;
   request.volume      = lots;
   request.type        = ORDER_TYPE_SELL;
   request.price       = bid;
   request.sl          = sl;
   request.tp          = tp;
   request.deviation   = 10;
   request.magic       = (ulong)123456;
   request.comment     = "AI SELL";
   ENUM_ORDER_TYPE_FILLING filling = GetFillingMode(sym);
   request.type_filling= filling;
   request.type_time   = ORDER_TIME_GTC;
   bool sent = OrderSend(request, result);
   if(!sent || result.retcode != TRADE_RETCODE_DONE)
     {
      PrintFormat("OrderSend failed: retcode=%d comment=%s", result.retcode, result.comment);
      return false;
     }
   PrintFormat("SELL opened: ticket=%d @ %.5f SL=%.5f TP=%.5f",
               result.order, bid, sl, tp);
   return true;
  }
// Convert to upper
string StringToUpperHelper(const string str)
  {
   string result = "";
   for(int i = 0; i < StringLen(str); i++)
     {
      ushort c = StringGetCharacter(str, i);
      if(c >= 'a' && c <= 'z') c = c - ('a' - 'A');
      result += CharToString((uchar)c);
     }
   return result;
  }
// Get filling mode
ENUM_ORDER_TYPE_FILLING GetFillingMode(const string symbol)
  {
   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }
//+------------------------------------------------------------------+
