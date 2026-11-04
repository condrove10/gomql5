package mt5_test

import (
	"context"
	"encoding/json"
	"log/slog"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/condrove10/gomql5/mt5"
	"github.com/condrove10/gomql5/mt5/mt5test"
	"github.com/condrove10/gomql5/protocol"
)

// TestWireContract pins, for every typed wrapper, the method name and the
// exact flat params sent to the EA (docs/protocol.md "Methods"), and that a
// canned result decodes. A renamed method or param would break the EA
// silently; this catches it on the Go side.
func TestWireContract(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 3, 1, 10, 0, 0, 0, time.FixedZone("EET", 2*3600)) // sent by wall clock
	t0w := float64(time.Date(2026, 3, 1, 10, 0, 0, 0, time.UTC).Unix())
	t1 := t0.Add(90*time.Minute + 250*time.Millisecond)
	t1w := t0w + 5400

	type tc struct {
		method string
		result string
		want   map[string]any // expected params (besides id/method)
		call   func(*mt5.Terminal) (any, error)
		check  func(any) bool
	}
	cases := []tc{
		{"ping", `{"time":1700000000}`, map[string]any{},
			func(t *mt5.Terminal) (any, error) { return t.Ping(ctx) },
			func(v any) bool { return v.(int64) == 1700000000 }},
		{"terminal_info", `{"connected":true,"build":6295,"name":"MetaTrader 5"}`, map[string]any{},
			func(t *mt5.Terminal) (any, error) { return t.TerminalInfo(ctx) },
			func(v any) bool { ti := v.(mt5.TerminalInfo); return ti.Connected && ti.Build == 6295 }},
		{"symbols_total", `{"total":42}`, map[string]any{"selected": true},
			func(t *mt5.Terminal) (any, error) { return t.SymbolsTotal(ctx, true) },
			func(v any) bool { return v.(int) == 42 }},
		{"symbols_get", `["XAUUSD","GOLD"]`, map[string]any{"group": "*XAU*,*GOLD*", "selected": false},
			func(t *mt5.Terminal) (any, error) { return t.SymbolsGet(ctx, "*XAU*,*GOLD*", false) },
			func(v any) bool { return reflect.DeepEqual(v, []string{"XAUUSD", "GOLD"}) }},
		{"symbol_info", `{"name":"XAUUSD","digits":2,"trade_contract_size":100}`, map[string]any{"symbol": "XAUUSD"},
			func(t *mt5.Terminal) (any, error) { return t.SymbolInfo(ctx, "XAUUSD") },
			func(v any) bool { si := v.(mt5.SymbolInfo); return si.Digits == 2 && si.TradeContractSize == 100 }},
		{"symbol_info_tick", `{"time":1,"bid":4001.1,"ask":4001.4,"time_msc":1001,"flags":6}`, map[string]any{"symbol": "XAUUSD"},
			func(t *mt5.Terminal) (any, error) { return t.SymbolInfoTick(ctx, "XAUUSD") },
			func(v any) bool { tk := v.(mt5.Tick); return tk.Ask == 4001.4 && tk.TimeMsc == 1001 }},
		{"symbol_select", `true`, map[string]any{"symbol": "XAUUSD", "enable": true},
			func(t *mt5.Terminal) (any, error) { return nil, t.SymbolSelect(ctx, "XAUUSD", true) },
			func(any) bool { return true }},
		{"copy_rates_from_pos", `[[1700000000,1,2,0.5,1.5,10,3,0]]`,
			map[string]any{"symbol": "XAUUSD", "timeframe": float64(mt5.TimeframeM1), "start": float64(0), "count": float64(5)},
			func(t *mt5.Terminal) (any, error) { return t.CopyRatesFromPos(ctx, "XAUUSD", mt5.TimeframeM1, 0, 5) },
			func(v any) bool { r := v.([]mt5.Rate); return len(r) == 1 && r[0].Close == 1.5 && r[0].Spread == 3 }},
		{"copy_rates_range", `[]`,
			map[string]any{"symbol": "XAUUSD", "timeframe": float64(mt5.TimeframeH1), "from": t0w, "to": t1w},
			func(t *mt5.Terminal) (any, error) { return t.CopyRatesRange(ctx, "XAUUSD", mt5.TimeframeH1, t0, t1) },
			func(v any) bool { return len(v.([]mt5.Rate)) == 0 }},
		{"copy_ticks_range", `[[1,1,2,0,0,1500,6,0]]`,
			map[string]any{"symbol": "XAUUSD", "from_msc": t0w * 1000, "to_msc": t1w*1000 + 250, "flags": float64(mt5.CopyTicksAll)},
			func(t *mt5.Terminal) (any, error) { return t.CopyTicksRange(ctx, "XAUUSD", t0, t1, mt5.CopyTicksAll) },
			func(v any) bool { tk := v.([]mt5.Tick); return len(tk) == 1 && tk[0].TimeMsc == 1500 }},
		{"orders_get", `[{"ticket":5,"symbol":"XAUUSD"}]`, map[string]any{"symbol": "XAUUSD", "ticket": float64(0)},
			func(t *mt5.Terminal) (any, error) { return t.OrdersGet(ctx, mt5.Filter{Symbol: "XAUUSD"}) },
			func(v any) bool { o := v.([]mt5.TradeOrder); return len(o) == 1 && o[0].Ticket == 5 }},
		{"positions_get", `[{"ticket":9}]`, map[string]any{"symbol": "", "ticket": float64(9)},
			func(t *mt5.Terminal) (any, error) { return t.PositionsGet(ctx, mt5.Filter{Ticket: 9}) },
			func(v any) bool { p := v.([]mt5.TradePosition); return len(p) == 1 && p[0].Ticket == 9 }},
		{"history_orders_get", `[]`, map[string]any{"symbol": "", "ticket": float64(0), "from": t0w, "to": float64(0)},
			func(t *mt5.Terminal) (any, error) { return t.HistoryOrdersGet(ctx, t0, time.Time{}, mt5.Filter{}) },
			func(any) bool { return true }},
		{"history_deals_get", `[{"ticket":3,"order":2}]`, map[string]any{"symbol": "XAUUSD", "ticket": float64(0), "from": t0w, "to": t1w},
			func(t *mt5.Terminal) (any, error) {
				return t.HistoryDealsGet(ctx, t0, t1, mt5.Filter{Symbol: "XAUUSD"})
			},
			func(v any) bool { d := v.([]mt5.TradeDeal); return len(d) == 1 && d[0].Order == 2 }},
		{"order_check", `{"retcode":0,"margin":12.5,"comment":"Done"}`,
			map[string]any{"action": float64(1), "magic": float64(0), "order": float64(0), "symbol": "XAUUSD", "volume": 0.01,
				"price": float64(0), "stoplimit": float64(0), "sl": float64(0), "tp": float64(0), "deviation": float64(0),
				"type": float64(0), "type_filling": float64(0), "type_time": float64(0), "expiration": float64(0),
				"comment": "", "position": float64(0), "position_by": float64(0)},
			func(t *mt5.Terminal) (any, error) {
				return t.OrderCheck(ctx, mt5.TradeRequest{Action: mt5.TradeActionDeal, Symbol: "XAUUSD", Volume: 0.01})
			},
			func(v any) bool { r := v.(mt5.OrderCheckResult); return r.Margin == 12.5 && r.Comment == "Done" }},
		{"subscribe_ticks", `true`, map[string]any{"symbol": "XAUUSD"},
			func(t *mt5.Terminal) (any, error) { return nil, t.SubscribeTicks(ctx, "XAUUSD") },
			func(any) bool { return true }},
		{"unsubscribe_ticks", `true`, map[string]any{"symbol": ""},
			func(t *mt5.Terminal) (any, error) { return nil, t.UnsubscribeTicks(ctx, "") },
			func(any) bool { return true }},
	}

	ea := mt5test.New(token)
	for _, c := range cases {
		res := c.result
		ea.Handlers[c.method] = func(map[string]any) (any, *protocol.Error) { return json.RawMessage(res), nil }
	}
	_, term := setup(t, mt5.Config{PingInterval: -1}, ea)
	seen := map[string]bool{}
	for _, c := range cases {
		v, err := c.call(term)
		if err != nil {
			t.Errorf("%s: %v", c.method, err)
			continue
		}
		if !c.check(v) {
			t.Errorf("%s: bad decode %+v", c.method, v)
		}
		reqs := ea.Requests()
		got := reqs[len(reqs)-1]
		if got["method"] != c.method {
			t.Errorf("wrapper for %s sent method %v", c.method, got["method"])
			continue
		}
		params := map[string]any{}
		for k, v := range got {
			if k != "id" && k != "method" {
				params[k] = v
			}
		}
		if !reflect.DeepEqual(params, c.want) {
			t.Errorf("%s params:\n got  %v\n want %v", c.method, params, c.want)
		}
		seen[c.method] = true
	}
	// Every Method* constant exported by the package must be covered here
	// (order_send and account_info have their own tests).
	for _, m := range []string{mt5.MethodPing, mt5.MethodTerminalInfo, mt5.MethodSymbolsTotal, mt5.MethodSymbolsGet,
		mt5.MethodSymbolInfo, mt5.MethodSymbolInfoTick, mt5.MethodSymbolSelect, mt5.MethodCopyRatesFromPos,
		mt5.MethodCopyRatesRange, mt5.MethodCopyTicksRange, mt5.MethodOrdersGet, mt5.MethodPositionsGet,
		mt5.MethodHistoryOrdersGet, mt5.MethodHistoryDealsGet, mt5.MethodOrderCheck, mt5.MethodSubscribeTicks,
		mt5.MethodUnsubscribeTicks} {
		if !seen[m] {
			t.Errorf("method %s not covered", m)
		}
	}
}

// logSink captures slog records.
type logSink struct {
	mu   sync.Mutex
	msgs []string
}

// Enabled mirrors a default production handler (Info and above), so a
// message demoted to Debug is not seen.
func (s *logSink) Enabled(_ context.Context, l slog.Level) bool { return l >= slog.LevelInfo }
func (s *logSink) Handle(_ context.Context, r slog.Record) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	line := r.Message
	r.Attrs(func(a slog.Attr) bool { line += " " + a.String(); return true })
	s.msgs = append(s.msgs, line)
	return nil
}
func (s *logSink) WithAttrs([]slog.Attr) slog.Handler { return s }
func (s *logSink) WithGroup(string) slog.Handler      { return s }
func (s *logSink) has(sub string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, m := range s.msgs {
		if strings.Contains(m, sub) {
			return true
		}
	}
	return false
}

// TestEventPaths: "log" events reach the logger, a malformed tick is logged
// and skipped (the connection survives), unknown events are ignored.
func TestEventPaths(t *testing.T) {
	sink := &logSink{}
	ea := mt5test.New(token)
	_, term := setup(t, mt5.Config{Logger: slog.New(sink), PingInterval: -1}, ea)
	ea.SendEvent("log", "hello from the EA")
	ea.SendEvent("tick", []int{1, 2}) // wrong arity array
	ea.SendEvent("something_new", map[string]any{"x": 1})
	ea.SendEvent("tick", map[string]any{"symbol": "XAUUSD", "bid": 1.5, "time_msc": 7})
	select {
	case tk := <-term.Ticks():
		if tk.Symbol != "XAUUSD" || tk.TimeMsc != 7 {
			t.Fatalf("tick %+v", tk)
		}
	case <-time.After(time.Second):
		t.Fatal("good tick after a bad one not delivered")
	}
	if _, err := term.Ping(context.Background()); err != nil {
		t.Fatalf("connection did not survive bad events: %v", err)
	}
	if !sink.has("hello from the EA") || !sink.has("bad tick event") {
		t.Fatalf("logs: %v", sink.msgs)
	}
	if term.RemoteAddr() == nil {
		t.Fatal("RemoteAddr nil")
	}
}

func TestServerTimeHelpers(t *testing.T) {
	if got := mt5.ServerTime(1700000000); got.Location() != time.UTC || got.Unix() != 1700000000 {
		t.Fatal(got)
	}
	if got := mt5.ServerTimeMsc(1700000000123); got.UnixMilli() != 1700000000123 || got.Location() != time.UTC {
		t.Fatal(got)
	}
}
