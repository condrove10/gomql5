//+------------------------------------------------------------------+
//| GoBridge.mq5 - MetaTrader 5 side of the gomql5 bridge            |
//|                                                                  |
//| Connects OUT to a Go mt5.Server (MQL5 sockets cannot listen),    |
//| sends a hello with the shared token, then answers requests.      |
//| Wire format: 4-byte big-endian length + UTF-8 JSON. See          |
//| docs/protocol.md. The Go host must be in Tools > Options >       |
//| Expert Advisors > "Allow WebRequest for listed URL".             |
//| MIT License - https://github.com/condrove10/gomql5               |
//+------------------------------------------------------------------+
#property copyright "gomql5 contributors"
#property link      "https://github.com/condrove10/gomql5"
#property version   "1.00"
#property description "gomql5 bridge: serves the Go mt5 package over TCP."
#property description "Add the Go host to the allowed WebRequest URL list (Tools > Options > Expert Advisors)."

#include <GoBridge/Json.mqh>

input string InpHost        = "127.0.0.1"; // Go server host
input uint   InpPort        = 7788;        // Go server port
input string InpToken       = "";          // Shared token (must match mt5.Config.Token)
input int    InpTimerMs     = 10;          // Poll period, ms
input int    InpReconnectMs = 2000;        // Delay between connect attempts, ms
input int    InpMaxItems    = 200000;      // Max bars/ticks/rows per response

#define EA_VERSION    "0.1.0"
#define PROTO_VERSION 1
#define MAX_FRAME     33554432

// Bridge error codes (mirror protocol/protocol.go)
#define E_FAIL           -1
#define E_INVALID_PARAMS -2
#define E_NOT_FOUND      -4
#define E_UNSUPPORTED    -7

int    g_sock         = INVALID_HANDLE;
uchar  g_rx[];
ulong  g_next_connect = 0;
string g_subs[];
long   g_sub_last[];

//+------------------------------------------------------------------+
string g_token="";

int OnInit()
  {
   g_token=InpToken;
   StringTrimLeft(g_token);
   StringTrimRight(g_token);
   if(g_token=="")
     {
      Print("GoBridge: InpToken is empty; set it to the Go server's Config.Token");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(!EventSetMillisecondTimer(MathMax(InpTimerMs,1)))
     {
      PrintFormat("GoBridge: EventSetMillisecondTimer failed: %d",GetLastError());
      return(INIT_FAILED);
     }
   PrintFormat("GoBridge %s: will connect to %s:%u",EA_VERSION,InpHost,InpPort);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Disconnect("deinit");
  }

void OnTimer()
  {
   if(g_sock==INVALID_HANDLE)
     {
      TryConnect();
      return;
     }
   if(!SocketIsConnected(g_sock))
     {
      Disconnect("peer closed");
      return;
     }
   if(!Pump())
      return;
   PollTicks();
  }

void OnTick()
  {
   if(g_sock!=INVALID_HANDLE)
      PollTicks();
  }

//+------------------------------------------------------------------+
//| Connection                                                       |
//+------------------------------------------------------------------+
void TryConnect()
  {
   ulong now=GetTickCount64();
   if(now<g_next_connect)
      return;
   g_next_connect=now+(ulong)MathMax(InpReconnectMs,100);

   ResetLastError();
   int s=SocketCreate();
   if(s==INVALID_HANDLE)
     {
      PrintFormat("GoBridge: SocketCreate failed: %d",GetLastError());
      return;
     }
   if(!SocketConnect(s,InpHost,InpPort,3000))
     {
      int e=GetLastError();
      if(e==4014)
         PrintFormat("GoBridge: connect %s:%u not allowed (4014): add '%s' to Tools > Options > Expert Advisors > Allow WebRequest for listed URL",InpHost,InpPort,InpHost);
      else
         PrintFormat("GoBridge: connect %s:%u failed: %d (is the Go server running?)",InpHost,InpPort,e);
      SocketClose(s);
      return;
     }
   SocketTimeouts(s,5000,5000);
   g_sock=s;
   ArrayResize(g_rx,0);
   ArrayResize(g_subs,0);
   ArrayResize(g_sub_last,0);

   CJsonWriter w;
   w.BeginObject();
   w.KStr("type","hello");
   w.KLong("proto",PROTO_VERSION);
   w.KStr("token",g_token);
   w.KStr("ea_version",EA_VERSION);
   w.KLong("build",TerminalInfoInteger(TERMINAL_BUILD));
   w.KLong("login",AccountInfoInteger(ACCOUNT_LOGIN));
   w.KStr("server",AccountInfoString(ACCOUNT_SERVER));
   w.KStr("company",AccountInfoString(ACCOUNT_COMPANY));
   w.EndObject();
   if(SendFrame(w.Text()))
      PrintFormat("GoBridge: connected to %s:%u",InpHost,InpPort);
  }

void Disconnect(const string why)
  {
   if(g_sock!=INVALID_HANDLE)
     {
      SocketClose(g_sock);
      g_sock=INVALID_HANDLE;
      PrintFormat("GoBridge: disconnected (%s)",why);
     }
   ArrayResize(g_rx,0);
   ArrayResize(g_subs,0);
   ArrayResize(g_sub_last,0);
  }

bool SendFrame(const string json)
  {
   if(g_sock==INVALID_HANDLE)
      return false;
   uchar body[];
   int n=StringToCharArray(json,body,0,WHOLE_ARRAY,CP_UTF8);
   if(n>0 && body[n-1]==0)
      n--; // drop the terminating zero StringToCharArray appends
   if(n<=0 || n>MAX_FRAME)
     {
      PrintFormat("GoBridge: refusing to send frame of %d bytes",n);
      return false;
     }
   uchar frame[];
   ArrayResize(frame,n+4);
   frame[0]=(uchar)((n>>24)&0xFF);
   frame[1]=(uchar)((n>>16)&0xFF);
   frame[2]=(uchar)((n>>8)&0xFF);
   frame[3]=(uchar)(n&0xFF);
   ArrayCopy(frame,body,4,0,n);
   int left=n+4;
   while(left>0)
     {
      int sent=SocketSend(g_sock,frame,(uint)left);
      if(sent<=0)
        {
         Disconnect(StringFormat("send failed: %d",GetLastError()));
         return false;
        }
      left-=sent;
      if(left>0)
         ArrayRemove(frame,0,sent);
     }
   return true;
  }

// Reads everything available and handles complete frames. False if disconnected.
bool Pump()
  {
   uint avail=SocketIsReadable(g_sock);
   while(avail>0)
     {
      uchar tmp[];
      int got=SocketRead(g_sock,tmp,avail,100);
      if(got<=0)
        {
         Disconnect(StringFormat("read failed: %d",GetLastError()));
         return false;
        }
      int old=ArraySize(g_rx);
      ArrayResize(g_rx,old+got,65536);
      ArrayCopy(g_rx,tmp,old,0,got);
      avail=SocketIsReadable(g_sock);
     }
   int total=ArraySize(g_rx);
   int pos=0;
   while(total-pos>=4)
     {
      uint len=((uint)g_rx[pos]<<24)|((uint)g_rx[pos+1]<<16)|((uint)g_rx[pos+2]<<8)|(uint)g_rx[pos+3];
      if(len==0 || len>MAX_FRAME)
        {
         Disconnect(StringFormat("bad frame length %u",len));
         return false;
        }
      if(total-pos-4<(int)len)
         break;
      string msg=CharArrayToString(g_rx,pos+4,(int)len,CP_UTF8);
      pos+=4+(int)len;
      HandleMessage(msg);
      if(g_sock==INVALID_HANDLE)
         return false;
     }
   if(pos>0)
      ArrayRemove(g_rx,0,pos);
   return true;
  }

//+------------------------------------------------------------------+
//| Request dispatch                                                 |
//+------------------------------------------------------------------+
void HandleMessage(const string msg)
  {
   CFlatJson req;
   if(!req.Parse(msg))
     {
      SendError(0,E_INVALID_PARAMS,"bad request: "+req.Error());
      return;
     }
   long id=req.GetLong("id");
   string method=req.GetString("method");
   CJsonWriter w;
   int code=0;
   string err="";
   ResetLastError();
   if(Dispatch(method,req,w,code,err))
     {
      string res="{\"type\":\"res\",\"id\":"+IntegerToString(id)+",\"ok\":true,\"result\":";
      string body=w.Text();
      if(body=="")
         body="null";
      StringAdd(res,body);
      StringAdd(res,"}");
      SendFrame(res);
     }
   else
      SendError(id,code,err);
  }

void SendError(const long id,const int code,const string message)
  {
   CJsonWriter w;
   w.BeginObject();
   w.KStr("type","res");
   w.KLong("id",id);
   w.KBool("ok",false);
   w.Key("error");
   w.BeginObject();
   w.KLong("code",code);
   w.KStr("message",message);
   w.EndObject();
   w.EndObject();
   SendFrame(w.Text());
  }

bool Fail(int &code,string &err,const int c,const string m)
  {
   code=c;
   err=m;
   return false;
  }

bool FailLast(int &code,string &err,const string what)
  {
   int e=GetLastError();
   if(e==0)
      e=E_FAIL;
   code=e;
   err=StringFormat("%s failed (MQL5 error %d)",what,e);
   return false;
  }

bool Dispatch(const string m,CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   if(m=="ping")
      return M_Ping(w);
   if(m=="terminal_info")
      return M_TerminalInfo(w);
   if(m=="account_info")
      return M_AccountInfo(w);
   if(m=="symbols_total")
      return M_SymbolsTotal(p,w);
   if(m=="symbols_get")
      return M_SymbolsGet(p,w);
   if(m=="symbol_info")
      return M_SymbolInfo(p,w,code,err);
   if(m=="symbol_info_tick")
      return M_SymbolInfoTick(p,w,code,err);
   if(m=="symbol_select")
      return M_SymbolSelect(p,w,code,err);
   if(m=="copy_rates_from_pos")
      return M_CopyRatesFromPos(p,w,code,err);
   if(m=="copy_rates_range")
      return M_CopyRatesRange(p,w,code,err);
   if(m=="copy_ticks_range")
      return M_CopyTicksRange(p,w,code,err);
   if(m=="orders_get")
      return M_OrdersGet(p,w);
   if(m=="positions_get")
      return M_PositionsGet(p,w);
   if(m=="history_orders_get")
      return M_HistoryOrdersGet(p,w,code,err);
   if(m=="history_deals_get")
      return M_HistoryDealsGet(p,w,code,err);
   if(m=="order_check")
      return M_OrderCheck(p,w,code,err);
   if(m=="order_send")
      return M_OrderSend(p,w,code,err);
   if(m=="subscribe_ticks")
      return M_Subscribe(p,w,code,err);
   if(m=="unsubscribe_ticks")
      return M_Unsubscribe(p,w);
   return Fail(code,err,E_UNSUPPORTED,"unknown method '"+m+"'");
  }

bool RequireSymbol(CFlatJson &p,string &sym,int &code,string &err)
  {
   sym=p.GetString("symbol");
   if(sym=="")
      return Fail(code,err,E_INVALID_PARAMS,"symbol is required");
   bool custom=false;
   if(!SymbolExist(sym,custom))
      return Fail(code,err,E_NOT_FOUND,"symbol '"+sym+"' not found");
   return true;
  }

//+------------------------------------------------------------------+
//| Methods                                                          |
//+------------------------------------------------------------------+
bool M_Ping(CJsonWriter &w)
  {
   w.BeginObject();
   w.KLong("time",(long)TimeTradeServer());
   w.EndObject();
   return true;
  }

bool M_TerminalInfo(CJsonWriter &w)
  {
   w.BeginObject();
   w.KBool("connected",TerminalInfoInteger(TERMINAL_CONNECTED)!=0);
   w.KBool("dlls_allowed",TerminalInfoInteger(TERMINAL_DLLS_ALLOWED)!=0);
   w.KBool("trade_allowed",TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)!=0);
   w.KBool("ea_trade_allowed",MQLInfoInteger(MQL_TRADE_ALLOWED)!=0);
   w.KLong("build",TerminalInfoInteger(TERMINAL_BUILD));
   w.KLong("maxbars",TerminalInfoInteger(TERMINAL_MAXBARS));
   w.KLong("codepage",TerminalInfoInteger(TERMINAL_CODEPAGE));
   w.KLong("ping_last",TerminalInfoInteger(TERMINAL_PING_LAST));
   w.KDbl("retransmission",TerminalInfoDouble(TERMINAL_RETRANSMISSION),4);
   w.KStr("company",TerminalInfoString(TERMINAL_COMPANY));
   w.KStr("name",TerminalInfoString(TERMINAL_NAME));
   w.KStr("language",TerminalInfoString(TERMINAL_LANGUAGE));
   w.KStr("path",TerminalInfoString(TERMINAL_PATH));
   w.KStr("data_path",TerminalInfoString(TERMINAL_DATA_PATH));
   w.KStr("commondata_path",TerminalInfoString(TERMINAL_COMMONDATA_PATH));
   w.EndObject();
   return true;
  }

bool M_AccountInfo(CJsonWriter &w)
  {
   w.BeginObject();
   w.KLong("login",AccountInfoInteger(ACCOUNT_LOGIN));
   w.KLong("trade_mode",AccountInfoInteger(ACCOUNT_TRADE_MODE));
   w.KLong("leverage",AccountInfoInteger(ACCOUNT_LEVERAGE));
   w.KLong("limit_orders",AccountInfoInteger(ACCOUNT_LIMIT_ORDERS));
   w.KLong("margin_so_mode",AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE));
   w.KBool("trade_allowed",AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)!=0);
   w.KBool("trade_expert",AccountInfoInteger(ACCOUNT_TRADE_EXPERT)!=0);
   w.KLong("margin_mode",AccountInfoInteger(ACCOUNT_MARGIN_MODE));
   w.KLong("currency_digits",AccountInfoInteger(ACCOUNT_CURRENCY_DIGITS));
   w.KBool("fifo_close",AccountInfoInteger(ACCOUNT_FIFO_CLOSE)!=0);
   w.KDbl("balance",AccountInfoDouble(ACCOUNT_BALANCE));
   w.KDbl("credit",AccountInfoDouble(ACCOUNT_CREDIT));
   w.KDbl("profit",AccountInfoDouble(ACCOUNT_PROFIT));
   w.KDbl("equity",AccountInfoDouble(ACCOUNT_EQUITY));
   w.KDbl("margin",AccountInfoDouble(ACCOUNT_MARGIN));
   w.KDbl("margin_free",AccountInfoDouble(ACCOUNT_MARGIN_FREE));
   w.KDbl("margin_level",AccountInfoDouble(ACCOUNT_MARGIN_LEVEL));
   w.KDbl("margin_so_call",AccountInfoDouble(ACCOUNT_MARGIN_SO_CALL));
   w.KDbl("margin_so_so",AccountInfoDouble(ACCOUNT_MARGIN_SO_SO));
   w.KDbl("margin_initial",AccountInfoDouble(ACCOUNT_MARGIN_INITIAL));
   w.KDbl("margin_maintenance",AccountInfoDouble(ACCOUNT_MARGIN_MAINTENANCE));
   w.KDbl("assets",AccountInfoDouble(ACCOUNT_ASSETS));
   w.KDbl("liabilities",AccountInfoDouble(ACCOUNT_LIABILITIES));
   w.KDbl("commission_blocked",AccountInfoDouble(ACCOUNT_COMMISSION_BLOCKED));
   w.KStr("name",AccountInfoString(ACCOUNT_NAME));
   w.KStr("server",AccountInfoString(ACCOUNT_SERVER));
   w.KStr("currency",AccountInfoString(ACCOUNT_CURRENCY));
   w.KStr("company",AccountInfoString(ACCOUNT_COMPANY));
   w.EndObject();
   return true;
  }

bool M_SymbolsTotal(CFlatJson &p,CJsonWriter &w)
  {
   w.BeginObject();
   w.KLong("total",SymbolsTotal(p.GetBool("selected")));
   w.EndObject();
   return true;
  }

// Wildcard match supporting '*' only, case-insensitive like MT5 groups.
bool Glob(const string s,const int si,const string pat,const int pi)
  {
   int sn=StringLen(s), pn=StringLen(pat);
   if(pi==pn)
      return si==sn;
   ushort pc=StringGetCharacter(pat,pi);
   if(pc=='*')
     {
      for(int k=si; k<=sn; k++)
         if(Glob(s,k,pat,pi+1))
            return true;
      return false;
     }
   if(si==sn)
      return false;
   if(pc!=StringGetCharacter(s,si))
      return false;
   return Glob(s,si+1,pat,pi+1);
  }

// group syntax as in the Python package: "*USD*,!EUR*" (include, then exclude).
bool GroupMatch(const string name,const string group)
  {
   if(group=="")
      return true;
   string parts[];
   int n=StringSplit(group,',',parts);
   string up=name;
   StringToUpper(up);
   bool have_pos=false, pos_hit=false;
   for(int i=0; i<n; i++)
     {
      string pat=parts[i];
      StringTrimLeft(pat);
      StringTrimRight(pat);
      if(pat=="")
         continue;
      StringToUpper(pat);
      if(StringGetCharacter(pat,0)=='!')
        {
         if(Glob(up,0,StringSubstr(pat,1),0))
            return false;
        }
      else
        {
         have_pos=true;
         if(Glob(up,0,pat,0))
            pos_hit=true;
        }
     }
   return !have_pos || pos_hit;
  }

bool M_SymbolsGet(CFlatJson &p,CJsonWriter &w)
  {
   bool selected=p.GetBool("selected");
   string group=p.GetString("group");
   int n=SymbolsTotal(selected);
   w.BeginArray();
   for(int i=0; i<n; i++)
     {
      string name=SymbolName(i,selected);
      if(GroupMatch(name,group))
         w.Str(name);
     }
   w.EndArray();
   return true;
  }

bool M_SymbolInfo(CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   string s;
   if(!RequireSymbol(p,s,code,err))
      return false;
   bool custom=false;
   SymbolExist(s,custom);
   int digits=(int)SymbolInfoInteger(s,SYMBOL_DIGITS);
   w.BeginObject();
   w.KStr("name",s);
   w.KStr("description",SymbolInfoString(s,SYMBOL_DESCRIPTION));
   w.KStr("path",SymbolInfoString(s,SYMBOL_PATH));
   w.KStr("currency_base",SymbolInfoString(s,SYMBOL_CURRENCY_BASE));
   w.KStr("currency_profit",SymbolInfoString(s,SYMBOL_CURRENCY_PROFIT));
   w.KStr("currency_margin",SymbolInfoString(s,SYMBOL_CURRENCY_MARGIN));
   w.KBool("custom",custom);
   w.KBool("select",SymbolInfoInteger(s,SYMBOL_SELECT)!=0);
   w.KBool("visible",SymbolInfoInteger(s,SYMBOL_VISIBLE)!=0);
   w.KLong("digits",digits);
   w.KLong("spread",SymbolInfoInteger(s,SYMBOL_SPREAD));
   w.KBool("spread_float",SymbolInfoInteger(s,SYMBOL_SPREAD_FLOAT)!=0);
   w.KLong("trade_mode",SymbolInfoInteger(s,SYMBOL_TRADE_MODE));
   w.KLong("trade_calc_mode",SymbolInfoInteger(s,SYMBOL_TRADE_CALC_MODE));
   w.KLong("trade_exemode",SymbolInfoInteger(s,SYMBOL_TRADE_EXEMODE));
   w.KLong("filling_mode",SymbolInfoInteger(s,SYMBOL_FILLING_MODE));
   w.KLong("order_mode",SymbolInfoInteger(s,SYMBOL_ORDER_MODE));
   w.KLong("expiration_mode",SymbolInfoInteger(s,SYMBOL_EXPIRATION_MODE));
   w.KLong("trade_stops_level",SymbolInfoInteger(s,SYMBOL_TRADE_STOPS_LEVEL));
   w.KLong("trade_freeze_level",SymbolInfoInteger(s,SYMBOL_TRADE_FREEZE_LEVEL));
   w.KLong("swap_mode",SymbolInfoInteger(s,SYMBOL_SWAP_MODE));
   w.KLong("swap_rollover3days",SymbolInfoInteger(s,SYMBOL_SWAP_ROLLOVER3DAYS));
   w.KLong("time",SymbolInfoInteger(s,SYMBOL_TIME));
   w.KDbl("bid",SymbolInfoDouble(s,SYMBOL_BID),digits);
   w.KDbl("ask",SymbolInfoDouble(s,SYMBOL_ASK),digits);
   w.KDbl("last",SymbolInfoDouble(s,SYMBOL_LAST),digits);
   w.KDbl("point",SymbolInfoDouble(s,SYMBOL_POINT),10);
   w.KDbl("trade_tick_value",SymbolInfoDouble(s,SYMBOL_TRADE_TICK_VALUE),10);
   w.KDbl("trade_tick_size",SymbolInfoDouble(s,SYMBOL_TRADE_TICK_SIZE),10);
   w.KDbl("trade_contract_size",SymbolInfoDouble(s,SYMBOL_TRADE_CONTRACT_SIZE));
   w.KDbl("volume_min",SymbolInfoDouble(s,SYMBOL_VOLUME_MIN));
   w.KDbl("volume_max",SymbolInfoDouble(s,SYMBOL_VOLUME_MAX));
   w.KDbl("volume_step",SymbolInfoDouble(s,SYMBOL_VOLUME_STEP));
   w.KDbl("volume_limit",SymbolInfoDouble(s,SYMBOL_VOLUME_LIMIT));
   w.KDbl("swap_long",SymbolInfoDouble(s,SYMBOL_SWAP_LONG));
   w.KDbl("swap_short",SymbolInfoDouble(s,SYMBOL_SWAP_SHORT));
   w.KDbl("margin_initial",SymbolInfoDouble(s,SYMBOL_MARGIN_INITIAL));
   w.KDbl("margin_maintenance",SymbolInfoDouble(s,SYMBOL_MARGIN_MAINTENANCE));
   w.EndObject();
   return true;
  }

void WriteTickObject(CJsonWriter &w,const string sym,const MqlTick &t,const int digits)
  {
   w.BeginObject();
   if(sym!="")
      w.KStr("symbol",sym);
   w.KLong("time",(long)t.time);
   w.KDbl("bid",t.bid,digits);
   w.KDbl("ask",t.ask,digits);
   w.KDbl("last",t.last,digits);
   w.KLong("volume",(long)t.volume);
   w.KLong("time_msc",t.time_msc);
   w.KLong("flags",(long)t.flags);
   w.KDbl("volume_real",t.volume_real);
   w.EndObject();
  }

bool M_SymbolInfoTick(CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   string s;
   if(!RequireSymbol(p,s,code,err))
      return false;
   MqlTick t;
   if(!SymbolInfoTick(s,t))
      return FailLast(code,err,"SymbolInfoTick");
   WriteTickObject(w,"",t,(int)SymbolInfoInteger(s,SYMBOL_DIGITS));
   return true;
  }

bool M_SymbolSelect(CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   string s;
   if(!RequireSymbol(p,s,code,err))
      return false;
   if(!SymbolSelect(s,p.GetBool("enable",true)))
      return FailLast(code,err,"SymbolSelect");
   w.Bool(true);
   return true;
  }

void WriteRates(CJsonWriter &w,const MqlRates &r[],const int n,const int digits)
  {
   w.BeginArray();
   for(int i=0; i<n; i++)
     {
      w.BeginArray();
      w.Long((long)r[i].time);
      w.Dbl(r[i].open,digits);
      w.Dbl(r[i].high,digits);
      w.Dbl(r[i].low,digits);
      w.Dbl(r[i].close,digits);
      w.Long(r[i].tick_volume);
      w.Long(r[i].spread);
      w.Long(r[i].real_volume);
      w.EndArray();
     }
   w.EndArray();
  }

bool M_CopyRatesFromPos(CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   string s;
   if(!RequireSymbol(p,s,code,err))
      return false;
   long count=p.GetLong("count");
   long start=p.GetLong("start");
   if(count<=0 || start<0)
      return Fail(code,err,E_INVALID_PARAMS,"count must be > 0 and start >= 0");
   if(count>InpMaxItems)
      return Fail(code,err,E_INVALID_PARAMS,StringFormat("count %I64d exceeds InpMaxItems %d",count,InpMaxItems));
   MqlRates r[];
   int n=CopyRates(s,(ENUM_TIMEFRAMES)p.GetLong("timeframe"),(int)start,(int)count,r);
   if(n<0)
      return FailLast(code,err,"CopyRates");
   WriteRates(w,r,n,(int)SymbolInfoInteger(s,SYMBOL_DIGITS));
   return true;
  }

bool M_CopyRatesRange(CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   string s;
   if(!RequireSymbol(p,s,code,err))
      return false;
   datetime from=(datetime)p.GetLong("from");
   datetime to=(datetime)p.GetLong("to");
   if(to<from)
      return Fail(code,err,E_INVALID_PARAMS,"to < from");
   MqlRates r[];
   int n=CopyRates(s,(ENUM_TIMEFRAMES)p.GetLong("timeframe"),from,to,r);
   if(n<0)
      return FailLast(code,err,"CopyRates");
   if(n>InpMaxItems)
      return Fail(code,err,E_INVALID_PARAMS,StringFormat("%d bars exceed InpMaxItems %d; narrow the range",n,InpMaxItems));
   WriteRates(w,r,n,(int)SymbolInfoInteger(s,SYMBOL_DIGITS));
   return true;
  }

bool M_CopyTicksRange(CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   string s;
   if(!RequireSymbol(p,s,code,err))
      return false;
   ulong from=(ulong)p.GetLong("from_msc");
   ulong to=(ulong)p.GetLong("to_msc");
   if(to<from)
      return Fail(code,err,E_INVALID_PARAMS,"to_msc < from_msc");
   MqlTick t[];
   int n=CopyTicksRange(s,t,(uint)p.GetLong("flags",-1),from,to);
   if(n<0)
      return FailLast(code,err,"CopyTicksRange");
   if(n>InpMaxItems)
      return Fail(code,err,E_INVALID_PARAMS,StringFormat("%d ticks exceed InpMaxItems %d; narrow the range",n,InpMaxItems));
   int digits=(int)SymbolInfoInteger(s,SYMBOL_DIGITS);
   w.BeginArray();
   for(int i=0; i<n; i++)
     {
      w.BeginArray();
      w.Long((long)t[i].time);
      w.Dbl(t[i].bid,digits);
      w.Dbl(t[i].ask,digits);
      w.Dbl(t[i].last,digits);
      w.Long((long)t[i].volume);
      w.Long(t[i].time_msc);
      w.Long((long)t[i].flags);
      w.Dbl(t[i].volume_real);
      w.EndArray();
     }
   w.EndArray();
   return true;
  }

// --- orders (active: OrderGet*, history: HistoryOrderGet*) ---------
void WriteActiveOrder(CJsonWriter &w,const ulong ticket)
  {
   w.BeginObject();
   w.KLong("ticket",(long)ticket);
   w.KLong("time_setup",OrderGetInteger(ORDER_TIME_SETUP));
   w.KLong("time_setup_msc",OrderGetInteger(ORDER_TIME_SETUP_MSC));
   w.KLong("time_done",OrderGetInteger(ORDER_TIME_DONE));
   w.KLong("time_done_msc",OrderGetInteger(ORDER_TIME_DONE_MSC));
   w.KLong("time_expiration",OrderGetInteger(ORDER_TIME_EXPIRATION));
   w.KLong("type",OrderGetInteger(ORDER_TYPE));
   w.KLong("type_time",OrderGetInteger(ORDER_TYPE_TIME));
   w.KLong("type_filling",OrderGetInteger(ORDER_TYPE_FILLING));
   w.KLong("state",OrderGetInteger(ORDER_STATE));
   w.KLong("magic",OrderGetInteger(ORDER_MAGIC));
   w.KLong("position_id",OrderGetInteger(ORDER_POSITION_ID));
   w.KLong("position_by_id",OrderGetInteger(ORDER_POSITION_BY_ID));
   w.KLong("reason",OrderGetInteger(ORDER_REASON));
   w.KDbl("volume_initial",OrderGetDouble(ORDER_VOLUME_INITIAL));
   w.KDbl("volume_current",OrderGetDouble(ORDER_VOLUME_CURRENT));
   w.KDbl("price_open",OrderGetDouble(ORDER_PRICE_OPEN));
   w.KDbl("sl",OrderGetDouble(ORDER_SL));
   w.KDbl("tp",OrderGetDouble(ORDER_TP));
   w.KDbl("price_current",OrderGetDouble(ORDER_PRICE_CURRENT));
   w.KDbl("price_stoplimit",OrderGetDouble(ORDER_PRICE_STOPLIMIT));
   w.KStr("symbol",OrderGetString(ORDER_SYMBOL));
   w.KStr("comment",OrderGetString(ORDER_COMMENT));
   w.KStr("external_id",OrderGetString(ORDER_EXTERNAL_ID));
   w.EndObject();
  }

void WriteHistoryOrder(CJsonWriter &w,const ulong t)
  {
   w.BeginObject();
   w.KLong("ticket",(long)t);
   w.KLong("time_setup",HistoryOrderGetInteger(t,ORDER_TIME_SETUP));
   w.KLong("time_setup_msc",HistoryOrderGetInteger(t,ORDER_TIME_SETUP_MSC));
   w.KLong("time_done",HistoryOrderGetInteger(t,ORDER_TIME_DONE));
   w.KLong("time_done_msc",HistoryOrderGetInteger(t,ORDER_TIME_DONE_MSC));
   w.KLong("time_expiration",HistoryOrderGetInteger(t,ORDER_TIME_EXPIRATION));
   w.KLong("type",HistoryOrderGetInteger(t,ORDER_TYPE));
   w.KLong("type_time",HistoryOrderGetInteger(t,ORDER_TYPE_TIME));
   w.KLong("type_filling",HistoryOrderGetInteger(t,ORDER_TYPE_FILLING));
   w.KLong("state",HistoryOrderGetInteger(t,ORDER_STATE));
   w.KLong("magic",HistoryOrderGetInteger(t,ORDER_MAGIC));
   w.KLong("position_id",HistoryOrderGetInteger(t,ORDER_POSITION_ID));
   w.KLong("position_by_id",HistoryOrderGetInteger(t,ORDER_POSITION_BY_ID));
   w.KLong("reason",HistoryOrderGetInteger(t,ORDER_REASON));
   w.KDbl("volume_initial",HistoryOrderGetDouble(t,ORDER_VOLUME_INITIAL));
   w.KDbl("volume_current",HistoryOrderGetDouble(t,ORDER_VOLUME_CURRENT));
   w.KDbl("price_open",HistoryOrderGetDouble(t,ORDER_PRICE_OPEN));
   w.KDbl("sl",HistoryOrderGetDouble(t,ORDER_SL));
   w.KDbl("tp",HistoryOrderGetDouble(t,ORDER_TP));
   w.KDbl("price_current",HistoryOrderGetDouble(t,ORDER_PRICE_CURRENT));
   w.KDbl("price_stoplimit",HistoryOrderGetDouble(t,ORDER_PRICE_STOPLIMIT));
   w.KStr("symbol",HistoryOrderGetString(t,ORDER_SYMBOL));
   w.KStr("comment",HistoryOrderGetString(t,ORDER_COMMENT));
   w.KStr("external_id",HistoryOrderGetString(t,ORDER_EXTERNAL_ID));
   w.EndObject();
  }

bool M_OrdersGet(CFlatJson &p,CJsonWriter &w)
  {
   string sym=p.GetString("symbol");
   ulong want=(ulong)p.GetLong("ticket");
   int n=OrdersTotal();
   w.BeginArray();
   for(int i=0; i<n; i++)
     {
      ulong t=OrderGetTicket(i);
      if(t==0)
         continue;
      if(want>0 && t!=want)
         continue;
      if(want==0 && sym!="" && OrderGetString(ORDER_SYMBOL)!=sym)
         continue;
      WriteActiveOrder(w,t);
     }
   w.EndArray();
   return true;
  }

void WritePosition(CJsonWriter &w,const ulong ticket)
  {
   w.BeginObject();
   w.KLong("ticket",(long)ticket);
   w.KLong("time",PositionGetInteger(POSITION_TIME));
   w.KLong("time_msc",PositionGetInteger(POSITION_TIME_MSC));
   w.KLong("time_update",PositionGetInteger(POSITION_TIME_UPDATE));
   w.KLong("time_update_msc",PositionGetInteger(POSITION_TIME_UPDATE_MSC));
   w.KLong("type",PositionGetInteger(POSITION_TYPE));
   w.KLong("magic",PositionGetInteger(POSITION_MAGIC));
   w.KLong("identifier",PositionGetInteger(POSITION_IDENTIFIER));
   w.KLong("reason",PositionGetInteger(POSITION_REASON));
   w.KDbl("volume",PositionGetDouble(POSITION_VOLUME));
   w.KDbl("price_open",PositionGetDouble(POSITION_PRICE_OPEN));
   w.KDbl("sl",PositionGetDouble(POSITION_SL));
   w.KDbl("tp",PositionGetDouble(POSITION_TP));
   w.KDbl("price_current",PositionGetDouble(POSITION_PRICE_CURRENT));
   w.KDbl("swap",PositionGetDouble(POSITION_SWAP));
   w.KDbl("profit",PositionGetDouble(POSITION_PROFIT));
   w.KStr("symbol",PositionGetString(POSITION_SYMBOL));
   w.KStr("comment",PositionGetString(POSITION_COMMENT));
   w.KStr("external_id",PositionGetString(POSITION_EXTERNAL_ID));
   w.EndObject();
  }

bool M_PositionsGet(CFlatJson &p,CJsonWriter &w)
  {
   string sym=p.GetString("symbol");
   ulong want=(ulong)p.GetLong("ticket");
   int n=PositionsTotal();
   w.BeginArray();
   for(int i=0; i<n; i++)
     {
      ulong t=PositionGetTicket(i);
      if(t==0)
         continue;
      if(want>0 && t!=want)
         continue;
      if(want==0 && sym!="" && PositionGetString(POSITION_SYMBOL)!=sym)
         continue;
      WritePosition(w,t);
     }
   w.EndArray();
   return true;
  }

bool SelectHistory(CFlatJson &p,int &code,string &err)
  {
   datetime from=(datetime)p.GetLong("from");
   datetime to=(datetime)p.GetLong("to");
   if(to==0)
      to=TimeTradeServer()+86400;
   if(to<from)
      return Fail(code,err,E_INVALID_PARAMS,"to < from");
   if(!HistorySelect(from,to))
      return FailLast(code,err,"HistorySelect");
   return true;
  }

bool M_HistoryOrdersGet(CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   string sym=p.GetString("symbol");
   ulong want=(ulong)p.GetLong("ticket");
   if(want>0)
     {
      // as in Python: a ticket ignores the date range
      w.BeginArray();
      if(HistoryOrderSelect(want))
         WriteHistoryOrder(w,want);
      w.EndArray();
      return true;
     }
   if(!SelectHistory(p,code,err))
      return false;
   int n=HistoryOrdersTotal();
   w.BeginArray();
   for(int i=0; i<n; i++)
     {
      ulong t=HistoryOrderGetTicket(i);
      if(t==0)
         continue;
      if(sym!="" && HistoryOrderGetString(t,ORDER_SYMBOL)!=sym)
         continue;
      WriteHistoryOrder(w,t);
     }
   w.EndArray();
   return true;
  }

void WriteDeal(CJsonWriter &w,const ulong t)
  {
   w.BeginObject();
   w.KLong("ticket",(long)t);
   w.KLong("order",HistoryDealGetInteger(t,DEAL_ORDER));
   w.KLong("time",HistoryDealGetInteger(t,DEAL_TIME));
   w.KLong("time_msc",HistoryDealGetInteger(t,DEAL_TIME_MSC));
   w.KLong("type",HistoryDealGetInteger(t,DEAL_TYPE));
   w.KLong("entry",HistoryDealGetInteger(t,DEAL_ENTRY));
   w.KLong("magic",HistoryDealGetInteger(t,DEAL_MAGIC));
   w.KLong("position_id",HistoryDealGetInteger(t,DEAL_POSITION_ID));
   w.KLong("reason",HistoryDealGetInteger(t,DEAL_REASON));
   w.KDbl("volume",HistoryDealGetDouble(t,DEAL_VOLUME));
   w.KDbl("price",HistoryDealGetDouble(t,DEAL_PRICE));
   w.KDbl("commission",HistoryDealGetDouble(t,DEAL_COMMISSION));
   w.KDbl("swap",HistoryDealGetDouble(t,DEAL_SWAP));
   w.KDbl("profit",HistoryDealGetDouble(t,DEAL_PROFIT));
   w.KDbl("fee",HistoryDealGetDouble(t,DEAL_FEE));
   w.KStr("symbol",HistoryDealGetString(t,DEAL_SYMBOL));
   w.KStr("comment",HistoryDealGetString(t,DEAL_COMMENT));
   w.KStr("external_id",HistoryDealGetString(t,DEAL_EXTERNAL_ID));
   w.EndObject();
  }

bool M_HistoryDealsGet(CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   string sym=p.GetString("symbol");
   ulong want=(ulong)p.GetLong("ticket");
   if(want>0)
     {
      w.BeginArray();
      if(HistoryDealSelect(want))
         WriteDeal(w,want);
      w.EndArray();
      return true;
     }
   if(!SelectHistory(p,code,err))
      return false;
   int n=HistoryDealsTotal();
   w.BeginArray();
   for(int i=0; i<n; i++)
     {
      ulong t=HistoryDealGetTicket(i);
      if(t==0)
         continue;
      if(sym!="" && HistoryDealGetString(t,DEAL_SYMBOL)!=sym)
         continue;
      WriteDeal(w,t);
     }
   w.EndArray();
   return true;
  }

// --- trading -------------------------------------------------------
bool BuildRequest(CFlatJson &p,MqlTradeRequest &r,int &code,string &err)
  {
   ZeroMemory(r);
   r.action      =(ENUM_TRADE_REQUEST_ACTIONS)p.GetLong("action");
   r.magic       =(ulong)p.GetLong("magic");
   r.order       =(ulong)p.GetLong("order");
   r.symbol      =p.GetString("symbol");
   r.volume      =p.GetDouble("volume");
   r.price       =p.GetDouble("price");
   r.stoplimit   =p.GetDouble("stoplimit");
   r.sl          =p.GetDouble("sl");
   r.tp          =p.GetDouble("tp");
   r.deviation   =(ulong)p.GetLong("deviation");
   r.type        =(ENUM_ORDER_TYPE)p.GetLong("type");
   r.type_filling=(ENUM_ORDER_TYPE_FILLING)p.GetLong("type_filling");
   r.type_time   =(ENUM_ORDER_TYPE_TIME)p.GetLong("type_time");
   r.expiration  =(datetime)p.GetLong("expiration");
   r.comment     =p.GetString("comment");
   r.position    =(ulong)p.GetLong("position");
   r.position_by =(ulong)p.GetLong("position_by");
   if(r.action==0)
      return Fail(code,err,E_INVALID_PARAMS,"action is required");
   // Convenience: market deal without a price uses the current ask/bid.
   if(r.action==TRADE_ACTION_DEAL && r.price==0.0 && r.symbol!="")
     {
      MqlTick t;
      if(SymbolInfoTick(r.symbol,t))
         r.price=(r.type==ORDER_TYPE_BUY) ? t.ask : t.bid;
     }
   return true;
  }

bool M_OrderCheck(CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   MqlTradeRequest r;
   if(!BuildRequest(p,r,code,err))
      return false;
   MqlTradeCheckResult c;
   ZeroMemory(c);
   ResetLastError();
   bool ok=OrderCheck(r,c);
   if(!ok && c.retcode==0)
      return FailLast(code,err,"OrderCheck");
   w.BeginObject();
   w.KLong("retcode",(long)c.retcode);
   w.KDbl("balance",c.balance);
   w.KDbl("equity",c.equity);
   w.KDbl("profit",c.profit);
   w.KDbl("margin",c.margin);
   w.KDbl("margin_free",c.margin_free);
   w.KDbl("margin_level",c.margin_level);
   w.KStr("comment",c.comment);
   w.EndObject();
   return true;
  }

bool M_OrderSend(CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   MqlTradeRequest r;
   if(!BuildRequest(p,r,code,err))
      return false;
   MqlTradeResult res;
   ZeroMemory(res);
   ResetLastError();
   bool ok=OrderSend(r,res);
   if(!ok && res.retcode==0)
      return FailLast(code,err,"OrderSend");
   w.BeginObject();
   w.KLong("retcode",(long)res.retcode);
   w.KLong("deal",(long)res.deal);
   w.KLong("order",(long)res.order);
   w.KDbl("volume",res.volume);
   w.KDbl("price",res.price);
   w.KDbl("bid",res.bid);
   w.KDbl("ask",res.ask);
   w.KStr("comment",res.comment);
   w.KLong("request_id",(long)res.request_id);
   w.KLong("retcode_external",(long)res.retcode_external);
   w.EndObject();
   return true;
  }

// --- tick streaming ------------------------------------------------
int FindSub(const string s)
  {
   for(int i=0; i<ArraySize(g_subs); i++)
      if(g_subs[i]==s)
         return i;
   return -1;
  }

bool M_Subscribe(CFlatJson &p,CJsonWriter &w,int &code,string &err)
  {
   string s;
   if(!RequireSymbol(p,s,code,err))
      return false;
   if(!SymbolSelect(s,true))
      return FailLast(code,err,"SymbolSelect");
   if(FindSub(s)<0)
     {
      int n=ArraySize(g_subs);
      ArrayResize(g_subs,n+1);
      ArrayResize(g_sub_last,n+1);
      g_subs[n]=s;
      g_sub_last[n]=0;
     }
   w.Bool(true);
   return true;
  }

bool M_Unsubscribe(CFlatJson &p,CJsonWriter &w)
  {
   string s=p.GetString("symbol");
   if(s=="")
     {
      ArrayResize(g_subs,0);
      ArrayResize(g_sub_last,0);
     }
   else
     {
      int i=FindSub(s);
      if(i>=0)
        {
         ArrayRemove(g_subs,i,1);
         ArrayRemove(g_sub_last,i,1);
        }
     }
   w.Bool(true);
   return true;
  }

void PollTicks()
  {
   for(int i=0; i<ArraySize(g_subs) && g_sock!=INVALID_HANDLE; i++)
     {
      MqlTick t;
      if(!SymbolInfoTick(g_subs[i],t))
         continue;
      if(t.time_msc==g_sub_last[i])
         continue;
      g_sub_last[i]=t.time_msc;
      CJsonWriter w;
      w.BeginObject();
      w.KStr("type","event");
      w.KStr("event","tick");
      w.Key("data");
      WriteTickObject(w,g_subs[i],t,(int)SymbolInfoInteger(g_subs[i],SYMBOL_DIGITS));
      w.EndObject();
      SendFrame(w.Text());
     }
  }
//+------------------------------------------------------------------+
