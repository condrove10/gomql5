//+------------------------------------------------------------------+
//| Json.mqh - minimal JSON for the gomql5 bridge                    |
//|                                                                  |
//| CJsonWriter: streaming writer for arbitrary nested JSON.         |
//| CFlatJson:   parser for FLAT objects only (scalar values), which |
//|              is all the Go side ever sends (docs/protocol.md).   |
//| MIT License - https://github.com/condrove10/gomql5               |
//+------------------------------------------------------------------+
#ifndef GOBRIDGE_JSON_MQH
#define GOBRIDGE_JSON_MQH

#define JSON_MAX_DEPTH 32

//+------------------------------------------------------------------+
//| Streaming JSON writer                                            |
//+------------------------------------------------------------------+
class CJsonWriter
  {
private:
   string            m_buf;
   bool              m_comma[JSON_MAX_DEPTH];
   int               m_depth;
   bool              m_after_key;

   void              Sep(void)
     {
      if(m_after_key)
        {
         m_after_key=false;
         return;
        }
      if(m_depth>0)
        {
         if(m_comma[m_depth-1])
            StringAdd(m_buf,",");
         m_comma[m_depth-1]=true;
        }
     }

public:
                     CJsonWriter(void) : m_buf(""), m_depth(0), m_after_key(false) {}

   void              Reset(void) { m_buf=""; m_depth=0; m_after_key=false; }
   string            Text(void) const { return m_buf; }

   void              BeginObject(void)
     {
      Sep();
      StringAdd(m_buf,"{");
      if(m_depth<JSON_MAX_DEPTH)
         m_comma[m_depth]=false;
      m_depth++;
     }
   void              EndObject(void) { m_depth--; StringAdd(m_buf,"}"); }
   void              BeginArray(void)
     {
      Sep();
      StringAdd(m_buf,"[");
      if(m_depth<JSON_MAX_DEPTH)
         m_comma[m_depth]=false;
      m_depth++;
     }
   void              EndArray(void) { m_depth--; StringAdd(m_buf,"]"); }

   void              Key(const string k) { Sep(); StringAdd(m_buf,Quote(k)); StringAdd(m_buf,":"); m_after_key=true; }
   void              Str(const string v) { Sep(); StringAdd(m_buf,Quote(v)); }
   void              Long(const long v) { Sep(); StringAdd(m_buf,IntegerToString(v)); }
   void              Bool(const bool v) { Sep(); StringAdd(m_buf,v ? "true" : "false"); }
   void              Null(void) { Sep(); StringAdd(m_buf,"null"); }
   void              Dbl(const double v,const int digits=8) { Sep(); StringAdd(m_buf,FormatDouble(v,digits)); }

   // key/value shorthands
   void              KStr(const string k,const string v) { Key(k); Str(v); }
   void              KLong(const string k,const long v) { Key(k); Long(v); }
   void              KBool(const string k,const bool v) { Key(k); Bool(v); }
   void              KDbl(const string k,const double v,const int digits=8) { Key(k); Dbl(v,digits); }

   static string     Quote(const string s)
     {
      string out="\"";
      int n=StringLen(s);
      for(int i=0; i<n; i++)
        {
         ushort c=StringGetCharacter(s,i);
         if(c=='"')
            StringAdd(out,"\\\"");
         else
            if(c=='\\')
               StringAdd(out,"\\\\");
            else
               if(c=='\n')
                  StringAdd(out,"\\n");
               else
                  if(c=='\r')
                     StringAdd(out,"\\r");
                  else
                     if(c=='\t')
                        StringAdd(out,"\\t");
                     else
                        if(c<32)
                           StringAdd(out,StringFormat("\\u%04x",(int)c));
                        else
                           StringAdd(out,ShortToString(c));
        }
      StringAdd(out,"\"");
      return out;
     }

   // JSON has no NaN/Inf: they become null. Trailing zeros are trimmed.
   static string     FormatDouble(const double v,const int digits)
     {
      if(!MathIsValidNumber(v))
         return "null";
      string s=DoubleToString(v,digits);
      if(StringFind(s,".")>=0)
        {
         int n=StringLen(s);
         while(n>0 && StringGetCharacter(s,n-1)=='0')
            n--;
         if(n>0 && StringGetCharacter(s,n-1)=='.')
            n--;
         s=StringSubstr(s,0,n);
        }
      if(s=="-0" || s=="" || s=="-")
         s="0";
      return s;
     }
  };

//+------------------------------------------------------------------+
//| Flat JSON object parser                                          |
//+------------------------------------------------------------------+
#define FJ_NULL   0
#define FJ_STRING 1
#define FJ_NUMBER 2
#define FJ_BOOL   3

class CFlatJson
  {
private:
   string            m_keys[];
   string            m_vals[];
   int               m_types[];
   int               m_count;
   string            m_err;

   bool              Fail(const string why,const int pos)
     {
      m_err=StringFormat("%s at offset %d",why,pos);
      return false;
     }

   void              SkipWs(const string &s,int &i,const int n)
     {
      while(i<n)
        {
         ushort c=StringGetCharacter(s,i);
         if(c==' ' || c=='\t' || c=='\n' || c=='\r')
            i++;
         else
            break;
        }
     }

   int               HexVal(const ushort c)
     {
      if(c>='0' && c<='9')
         return c-'0';
      if(c>='a' && c<='f')
         return c-'a'+10;
      if(c>='A' && c<='F')
         return c-'A'+10;
      return -1;
     }

   bool              ParseString(const string &s,int &i,const int n,string &out)
     {
      // s[i] == '"'
      i++;
      out="";
      while(i<n)
        {
         ushort c=StringGetCharacter(s,i);
         if(c=='"')
           {
            i++;
            return true;
           }
         if(c=='\\')
           {
            i++;
            if(i>=n)
               return Fail("unterminated escape",i);
            ushort e=StringGetCharacter(s,i);
            if(e=='"')
               StringAdd(out,"\"");
            else
               if(e=='\\')
                  StringAdd(out,"\\");
               else
                  if(e=='/')
                     StringAdd(out,"/");
                  else
                     if(e=='b')
                        StringAdd(out,ShortToString(8));
                     else
                        if(e=='f')
                           StringAdd(out,ShortToString(12));
                        else
                           if(e=='n')
                              StringAdd(out,"\n");
                           else
                              if(e=='r')
                                 StringAdd(out,"\r");
                              else
                                 if(e=='t')
                                    StringAdd(out,"\t");
                                 else
                                    if(e=='u')
                                      {
                                       if(i+4>=n)
                                          return Fail("short \\u escape",i);
                                       int code=0;
                                       for(int k=1; k<=4; k++)
                                         {
                                          int h=HexVal(StringGetCharacter(s,i+k));
                                          if(h<0)
                                             return Fail("bad \\u escape",i);
                                          code=code*16+h;
                                         }
                                       StringAdd(out,ShortToString((ushort)code));
                                       i+=4;
                                      }
                                    else
                                       return Fail("bad escape",i);
            i++;
            continue;
           }
         StringAdd(out,ShortToString(c));
         i++;
        }
      return Fail("unterminated string",i);
     }

   void              Add(const string k,const string v,const int t)
     {
      for(int j=0; j<m_count; j++)
         if(m_keys[j]==k)
           {
            m_vals[j]=v;
            m_types[j]=t;
            return;
           }
      ArrayResize(m_keys,m_count+1,16);
      ArrayResize(m_vals,m_count+1,16);
      ArrayResize(m_types,m_count+1,16);
      m_keys[m_count]=k;
      m_vals[m_count]=v;
      m_types[m_count]=t;
      m_count++;
     }

   int               Find(const string k) const
     {
      for(int j=0; j<m_count; j++)
         if(m_keys[j]==k)
            return j;
      return -1;
     }

public:
                     CFlatJson(void) : m_count(0), m_err("") {}

   string            Error(void) const { return m_err; }
   int               Count(void) const { return m_count; }
   bool              Has(const string k) const { return Find(k)>=0; }

   bool              Parse(const string s)
     {
      m_count=0;
      m_err="";
      ArrayResize(m_keys,0);
      ArrayResize(m_vals,0);
      ArrayResize(m_types,0);
      int n=StringLen(s);
      int i=0;
      SkipWs(s,i,n);
      if(i>=n || StringGetCharacter(s,i)!='{')
         return Fail("expected '{'",i);
      i++;
      SkipWs(s,i,n);
      if(i<n && StringGetCharacter(s,i)=='}')
        {
         i++;
         SkipWs(s,i,n);
         return i==n ? true : Fail("trailing data",i);
        }
      while(i<n)
        {
         SkipWs(s,i,n);
         if(i>=n || StringGetCharacter(s,i)!='"')
            return Fail("expected key",i);
         string key;
         if(!ParseString(s,i,n,key))
            return false;
         SkipWs(s,i,n);
         if(i>=n || StringGetCharacter(s,i)!=':')
            return Fail("expected ':'",i);
         i++;
         SkipWs(s,i,n);
         if(i>=n)
            return Fail("expected value",i);
         ushort c=StringGetCharacter(s,i);
         if(c=='"')
           {
            string v;
            if(!ParseString(s,i,n,v))
               return false;
            Add(key,v,FJ_STRING);
           }
         else
            if(c=='{' || c=='[')
               return Fail("nested values are not supported",i);
            else
               if(c=='t' && StringSubstr(s,i,4)=="true")
                 {
                  Add(key,"1",FJ_BOOL);
                  i+=4;
                 }
               else
                  if(c=='f' && StringSubstr(s,i,5)=="false")
                    {
                     Add(key,"0",FJ_BOOL);
                     i+=5;
                    }
                  else
                     if(c=='n' && StringSubstr(s,i,4)=="null")
                       {
                        Add(key,"",FJ_NULL);
                        i+=4;
                       }
                     else
                       {
                        int start=i;
                        while(i<n)
                          {
                           ushort d=StringGetCharacter(s,i);
                           if((d>='0' && d<='9') || d=='-' || d=='+' || d=='.' || d=='e' || d=='E')
                              i++;
                           else
                              break;
                          }
                        if(i==start)
                           return Fail("unexpected character",i);
                        Add(key,StringSubstr(s,start,i-start),FJ_NUMBER);
                       }
         SkipWs(s,i,n);
         if(i>=n)
            return Fail("unterminated object",i);
         c=StringGetCharacter(s,i);
         i++;
         if(c==',')
            continue;
         if(c=='}')
           {
            SkipWs(s,i,n);
            return i==n ? true : Fail("trailing data",i);
           }
         return Fail("expected ',' or '}'",i-1);
        }
      return Fail("unterminated object",i);
     }

   string            GetString(const string k,const string def="") const
     {
      int j=Find(k);
      if(j<0 || m_types[j]==FJ_NULL)
         return def;
      return m_vals[j];
     }

   long              GetLong(const string k,const long def=0) const
     {
      int j=Find(k);
      if(j<0 || m_types[j]==FJ_NULL)
         return def;
      if(m_types[j]==FJ_NUMBER && (StringFind(m_vals[j],".")>=0 || StringFind(m_vals[j],"e")>=0 || StringFind(m_vals[j],"E")>=0))
         return (long)StringToDouble(m_vals[j]);
      return StringToInteger(m_vals[j]);
     }

   double            GetDouble(const string k,const double def=0.0) const
     {
      int j=Find(k);
      if(j<0 || m_types[j]==FJ_NULL)
         return def;
      return StringToDouble(m_vals[j]);
     }

   bool              GetBool(const string k,const bool def=false) const
     {
      int j=Find(k);
      if(j<0 || m_types[j]==FJ_NULL)
         return def;
      if(m_types[j]==FJ_BOOL)
         return m_vals[j]=="1";
      if(m_types[j]==FJ_NUMBER)
         return StringToDouble(m_vals[j])!=0.0;
      return m_vals[j]=="true" || m_vals[j]=="1";
     }
  };

#endif // GOBRIDGE_JSON_MQH
