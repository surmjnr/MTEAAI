#property strict

#property version "1.11"

#property description "AI-driven EA with WebRequest communication"



input string   AiServerURL    = "http://127.0.0.1:5000/predict";

input string   SymbolToTrade  = "EURUSD";

input ENUM_TIMEFRAMES TimeframeToWatch = PERIOD_H1;

input double   LotSizeDefault = 0.10;

input double   StopLossPips   = 30.0;

input double   TakeProfitPips = 60.0;

input int      RequestTimeout = 5000;
// Training endpoint (sent once per week when condition met)
input string   TrainURL        = "http://192.168.12.38:5000/train";
input int      BarsToSend      = 1000; // how many recent bars to include when training


datetime lastCheckedBar = 0;

string   g_symbol;
datetime lastWeeklyTrainSent = 0; // runtime guard so EA doesn't send twice per week

 



int OnInit()

  {

   g_symbol = SymbolToTrade;

   PrintFormat("AI_Trader_EA initialized. Symbol=%s, TF=%s, AI_URL=%s",

               g_symbol, EnumToString(TimeframeToWatch), AiServerURL);

   return(INIT_SUCCEEDED);

  }



void OnDeinit(const int reason)

  {

   Print("AI_Trader_EA deinitialized.");

  }



void OnTick()

  {

   datetime curBarTime = iTime(g_symbol, TimeframeToWatch, 0);

   if(curBarTime == 0) return;

   if(curBarTime == lastCheckedBar) return;

   lastCheckedBar = curBarTime;

  // Weekly training trigger: run once-per-week when Friday hour >= 23 (broker/server time)
  TryWeeklyTrainingTrigger();



   // FIXED: Check if position exists for this symbol correctly
   if(HasPositionForSymbol(g_symbol))

     {

      PrintFormat("Position already open for %s", g_symbol);

      return;

     }



   double open  = iOpen(g_symbol, TimeframeToWatch, 1);

   double high  = iHigh(g_symbol, TimeframeToWatch, 1);

   double low   = iLow(g_symbol, TimeframeToWatch, 1);

   double close = iClose(g_symbol, TimeframeToWatch, 1);

   long   vol   = (long)iVolume(g_symbol, TimeframeToWatch, 1);



   if(open == 0 && high == 0 && low == 0 && close == 0)

     {

      Print("No valid candle data.");

      return;

     }



   string payload = StringFormat(

      "{\"Symbol\":\"%s\",\"Timeframe\":\"%s\",\"Open\":%.5f,\"High\":%.5f,\"Low\":%.5f,\"Close\":%.5f,\"Volume\":%d}",

      g_symbol, EnumToString(TimeframeToWatch), open, high, low, close, vol

   );



   string ai_response = SendToAI(payload);



   if(StringLen(ai_response) == 0)

     {

      Print("AI response empty.");

      return;

     }



   string ai_up = StringToUpperHelper(ai_response);

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

      Print("AI returned no actionable signal. Response: ", ai_response);

     }

  }



// FIXED: Helper function to check if position exists for symbol

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



string SendToAI(const string payload)

  {

   string headers = "Content-Type: application/json\r\n";

   uchar post[];

   StringToCharArray(payload, post, 0, WHOLE_ARRAY, CP_UTF8);

   uchar result[];

   string result_headers = "";



   ResetLastError();

   int status = WebRequest("POST", AiServerURL, headers, RequestTimeout, post, result, result_headers);

   if(status == -1)

     {

      PrintFormat("WebRequest failed (Error %d)", GetLastError());

      return "";

     }



   if(status != 200)

     {

      string text = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

      PrintFormat("HTTP %d received. Body: %s", status, text);

      return "";

     }



   string response_text = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

   PrintFormat("AI response: %s", response_text);

   return response_text;

  }



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



// FIXED: Convert pips to points correctly (handles 4-digit and 5-digit brokers)

double PipsToPoints(const string symbol, double pips)

  {

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   // For 5-digit brokers, 1 pip = 10 points; for 4-digit, 1 pip = 1 point

   if(digits == 3 || digits == 5)

      return pips * point * 10.0;

   else

      return pips * point;

  }



bool OpenTradeBuy(const string sym, double lots, double slPips, double tpPips)

  {

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);



   // FIXED: Use proper pips to points conversion

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

   // FIXED: Check available filling mode

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

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);



   // FIXED: Use proper pips to points conversion

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

   // FIXED: Check available filling mode

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



// Helper function to convert string to uppercase (MQL5 doesn't have StringToUpper)

string StringToUpperHelper(const string str)

  {

   string result = "";

   for(int i = 0; i < StringLen(str); i++)

     {

      ushort c = StringGetCharacter(str, i);

      if(c >= 'a' && c <= 'z')

         c = c - ('a' - 'A');

      result += CharToString((uchar)c);

     }

   return result;

  }



// FIXED: Helper function to determine correct filling mode

ENUM_ORDER_TYPE_FILLING GetFillingMode(const string symbol)

  {

   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)

      return ORDER_FILLING_FOK;

   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)

      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;

  }

// --- Weekly training: collect recent bars and POST to TrainURL ---
void TryWeeklyTrainingTrigger()
  {
  MqlDateTime dt;
  TimeToStruct(TimeCurrent(), dt);
  int dow = dt.day_of_week; // 0=Sunday, 5=Friday
  int hr  = dt.hour;

   // Only trigger on Friday hour >= 23
   if(dow != 5 || hr < 23) return;

   // Ensure at least 7 days have passed since last send
   if((long)(TimeCurrent() - lastWeeklyTrainSent) < (7*24*3600))
     {
      Print("Weekly training already sent within last 7 days.");
      return;
     }

   Print("Weekly training condition met — collecting bars and sending to training server...");
   bool ok = SendTrainingData(BarsToSend); // collect up to BarsToSend recent bars
   if(ok)
     {
      lastWeeklyTrainSent = TimeCurrent();
      Print("Weekly training data sent successfully.");
     }
   else
     Print("Failed to send weekly training data.");
  }


bool SendTrainingData(int barsToCollect)
  {
   if(StringLen(TrainURL) == 0)
     {
      Print("TrainURL not configured.");
      return false;
     }

   int total = iBars(g_symbol, TimeframeToWatch);
   if(total <= 1)
     {
      Print("Not enough bars available to collect training data.");
      return false;
     }

   int count = MathMin(total - 1, barsToCollect);

   // Build JSON payload
   string json = StringFormat("{\"Symbol\":\"%s\",\"Timeframe\":\"%s\",\"Bars\":[",
                              g_symbol, EnumToString(TimeframeToWatch));

   for(int i = 1; i <= count; i++)
     {
      datetime t = iTime(g_symbol, TimeframeToWatch, i);
      double o = iOpen(g_symbol, TimeframeToWatch, i);
      double h = iHigh(g_symbol, TimeframeToWatch, i);
      double l = iLow(g_symbol, TimeframeToWatch, i);
      double c = iClose(g_symbol, TimeframeToWatch, i);
      long   v = (long)iVolume(g_symbol, TimeframeToWatch, i);

      string sep = (i == 1) ? "" : ",";
      // time as integer seconds since epoch
      json += StringFormat("%s{\"t\":%I64d,\"o\":%.5f,\"h\":%.5f,\"l\":%.5f,\"c\":%.5f,\"v\":%d}",
                           sep, t, o, h, l, c, v);
     }

   json += "]}";

   // Send via WebRequest
   string headers = "Content-Type: application/json\r\n";
   uchar post[];
   StringToCharArray(json, post, 0, WHOLE_ARRAY, CP_UTF8);
   uchar result[];
   string result_headers = "";

   ResetLastError();
   int status = WebRequest("POST", TrainURL, headers, RequestTimeout, post, result, result_headers);
   if(status == -1)
     {
      PrintFormat("Training WebRequest failed (Error %d)", GetLastError());
      return false;
     }

   string response_text = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(status != 200)
     {
      PrintFormat("Training HTTP %d: %s", status, response_text);
      return false;
     }

   PrintFormat("Training response: %s", response_text);
   return true;
  }
 

