package mt5_test

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/condrove10/gomql5/mt5"
	"github.com/condrove10/gomql5/mt5/mt5test"
	"github.com/condrove10/gomql5/protocol"
)

const token = "s3cret"

func setup(t *testing.T, cfg mt5.Config, ea *mt5test.FakeEA) (*mt5.Server, *mt5.Terminal) {
	t.Helper()
	if cfg.Token == "" {
		cfg.Token = token
	}
	srv, err := mt5.Listen("127.0.0.1:0", cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { srv.Close() })
	if err := ea.Dial(srv.Addr().String()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ea.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	term, err := srv.Accept(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { term.Close() })
	return srv, term
}

func TestTokenRequired(t *testing.T) {
	if _, err := mt5.Listen("127.0.0.1:0", mt5.Config{}); err == nil {
		t.Fatal("empty token without AllowNoToken must be rejected")
	}
}

func TestHandshakeRejectsBadToken(t *testing.T) {
	srv, err := mt5.Listen("127.0.0.1:0", mt5.Config{Token: token})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	ea := mt5test.New("wrong")
	if err := ea.Dial(srv.Addr().String()); err != nil {
		t.Fatal(err)
	}
	defer ea.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	if term, err := srv.Accept(ctx); err == nil {
		t.Fatalf("bad token accepted: %+v", term.Hello())
	}
}

func TestHandshakeRejectsWrongProto(t *testing.T) {
	srv, _ := mt5.Listen("127.0.0.1:0", mt5.Config{Token: token})
	defer srv.Close()
	ea := mt5test.New(token)
	ea.Hello.Proto = 99
	if err := ea.Dial(srv.Addr().String()); err != nil {
		t.Fatal(err)
	}
	defer ea.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	if _, err := srv.Accept(ctx); err == nil {
		t.Fatal("wrong protocol version accepted")
	}
}

func TestHelloExposedWithoutToken(t *testing.T) {
	_, term := setup(t, mt5.Config{}, mt5test.New(token))
	h := term.Hello()
	if h.Login != 12345 || h.Token != "" {
		t.Fatalf("unexpected hello %+v", h)
	}
}

func TestAccountInfoDecode(t *testing.T) {
	ea := mt5test.New(token)
	ea.Handlers["account_info"] = func(map[string]any) (any, *protocol.Error) {
		return json.RawMessage(`{"login":12345,"leverage":100,"balance":1000.5,"currency":"USD","trade_allowed":true}`), nil
	}
	_, term := setup(t, mt5.Config{}, ea)
	ai, err := term.AccountInfo(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if ai.Login != 12345 || ai.Leverage != 100 || ai.Balance != 1000.5 || ai.Currency != "USD" || !ai.TradeAllowed {
		t.Fatalf("bad decode %+v", ai)
	}
}

func TestRatesAndTicksArrayDecode(t *testing.T) {
	ea := mt5test.New(token)
	ea.Handlers["copy_rates_range"] = func(p map[string]any) (any, *protocol.Error) {
		if p["timeframe"].(float64) != float64(mt5.TimeframeH1) {
			return nil, &protocol.Error{Code: -2, Message: "bad timeframe"}
		}
		return json.RawMessage(`[[1700000000,1.1,1.2,1.0,1.15,42,3,0]]`), nil
	}
	ea.Handlers["copy_ticks_range"] = func(map[string]any) (any, *protocol.Error) {
		return json.RawMessage(`[[1700000000,1.1,1.2,0,0,1700000000123,6,0]]`), nil
	}
	_, term := setup(t, mt5.Config{}, ea)
	from := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	rates, err := term.CopyRatesRange(context.Background(), "EURUSD", mt5.TimeframeH1, from, from.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	want := mt5.Rate{Time: 1700000000, Open: 1.1, High: 1.2, Low: 1.0, Close: 1.15, TickVolume: 42, Spread: 3}
	if len(rates) != 1 || rates[0] != want {
		t.Fatalf("rates %+v", rates)
	}
	req := ea.Requests()[len(ea.Requests())-1]
	if req["from"].(float64) != float64(from.Unix()) || req["symbol"] != "EURUSD" {
		t.Fatalf("request params %+v", req)
	}
	ticks, err := term.CopyTicksRange(context.Background(), "EURUSD", from, from, mt5.CopyTicksAll)
	if err != nil {
		t.Fatal(err)
	}
	if len(ticks) != 1 || ticks[0].TimeMsc != 1700000000123 || ticks[0].Flags != mt5.TickFlagBid|mt5.TickFlagAsk {
		t.Fatalf("ticks %+v", ticks)
	}
}

func TestRateArrayWrongLength(t *testing.T) {
	var r mt5.Rate
	if err := json.Unmarshal([]byte(`[1,2,3]`), &r); err == nil {
		t.Fatal("short rate array must fail")
	}
}

func TestWallClockSent(t *testing.T) {
	// A time in a non-UTC zone must be sent by its wall-clock reading (MT5 server time).
	ea := mt5test.New(token)
	ea.Handlers["history_deals_get"] = func(map[string]any) (any, *protocol.Error) { return []any{}, nil }
	_, term := setup(t, mt5.Config{}, ea)
	loc := time.FixedZone("EET", 2*3600)
	from := time.Date(2026, 3, 1, 10, 0, 0, 0, loc)
	if _, err := term.HistoryDealsGet(context.Background(), from, from, mt5.Filter{}); err != nil {
		t.Fatal(err)
	}
	got := int64(ea.Requests()[len(ea.Requests())-1]["from"].(float64))
	if want := time.Date(2026, 3, 1, 10, 0, 0, 0, time.UTC).Unix(); got != want {
		t.Fatalf("from=%d want %d", got, want)
	}
}

func TestErrorResponse(t *testing.T) {
	ea := mt5test.New(token)
	ea.Handlers["symbol_info"] = func(map[string]any) (any, *protocol.Error) {
		return nil, &protocol.Error{Code: protocol.ErrCodeNotFound, Message: "symbol not found"}
	}
	_, term := setup(t, mt5.Config{}, ea)
	_, err := term.SymbolInfo(context.Background(), "NOPE")
	var pe *protocol.Error
	if !errors.As(err, &pe) || pe.Code != protocol.ErrCodeNotFound {
		t.Fatalf("want not-found protocol error, got %v", err)
	}
	// Unknown method path.
	err = term.Call(context.Background(), "does_not_exist", nil, nil)
	if !errors.As(err, &pe) || pe.Code != protocol.ErrCodeUnsupported {
		t.Fatalf("want unsupported, got %v", err)
	}
}

func TestOrderSendParams(t *testing.T) {
	ea := mt5test.New(token)
	ea.Handlers["order_send"] = func(p map[string]any) (any, *protocol.Error) {
		return map[string]any{"retcode": 10009, "order": 77, "volume": p["volume"]}, nil
	}
	_, term := setup(t, mt5.Config{}, ea)
	res, err := term.OrderSend(context.Background(), mt5.TradeRequest{
		Action: mt5.TradeActionDeal, Symbol: "EURUSD", Volume: 0.1, Type: mt5.OrderTypeBuy,
		TypeFilling: mt5.OrderFillingIoc, Deviation: 10, Magic: 42,
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Retcode != mt5.TradeRetcodeDone || res.Order != 77 || res.Volume != 0.1 {
		t.Fatalf("res %+v", res)
	}
	p := ea.Requests()[len(ea.Requests())-1]
	if p["action"].(float64) != 1 || p["type_filling"].(float64) != 1 || p["magic"].(float64) != 42 {
		t.Fatalf("params %+v", p)
	}
}

func TestRequestTimeout(t *testing.T) {
	ea := mt5test.New(token)
	ea.Handlers["account_info"] = func(map[string]any) (any, *protocol.Error) { return nil, mt5test.NoReply }
	_, term := setup(t, mt5.Config{RequestTimeout: 100 * time.Millisecond}, ea)
	start := time.Now()
	_, err := term.AccountInfo(context.Background())
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("want deadline exceeded, got %v", err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("timeout not honoured")
	}
	// Connection still usable after a timed-out request.
	if _, err := term.Ping(context.Background()); err != nil {
		t.Fatalf("ping after timeout: %v", err)
	}
}

func TestConcurrentCallsMatchIDs(t *testing.T) {
	ea := mt5test.New(token)
	ea.Handlers["symbol_info"] = func(p map[string]any) (any, *protocol.Error) {
		return map[string]any{"name": p["symbol"]}, nil
	}
	_, term := setup(t, mt5.Config{}, ea)
	syms := []string{"A", "B", "C", "D", "E", "F", "G", "H"}
	errs := make(chan error, len(syms)*20)
	for i := 0; i < 20; i++ {
		for _, s := range syms {
			go func(s string) {
				si, err := term.SymbolInfo(context.Background(), s)
				if err == nil && si.Name != s {
					err = errors.New("mismatched reply: asked " + s + " got " + si.Name)
				}
				errs <- err
			}(s)
		}
	}
	for i := 0; i < cap(errs); i++ {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
}

func TestDisconnectFailsPending(t *testing.T) {
	ea := mt5test.New(token)
	ea.Handlers["account_info"] = func(map[string]any) (any, *protocol.Error) { return nil, mt5test.NoReply }
	_, term := setup(t, mt5.Config{RequestTimeout: 5 * time.Second}, ea)
	go func() { time.Sleep(100 * time.Millisecond); ea.Close() }()
	start := time.Now()
	if _, err := term.AccountInfo(context.Background()); err == nil {
		t.Fatal("pending call must fail on disconnect")
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("pending call waited for the timeout instead of failing on disconnect")
	}
	select {
	case <-term.Done():
	case <-time.After(time.Second):
		t.Fatal("Done not closed")
	}
	if _, err := term.Ping(context.Background()); err == nil {
		t.Fatal("call after close must fail")
	}
}

func TestTickEvents(t *testing.T) {
	ea := mt5test.New(token)
	ea.Handlers["subscribe_ticks"] = func(map[string]any) (any, *protocol.Error) { return true, nil }
	_, term := setup(t, mt5.Config{}, ea)
	if err := term.SubscribeTicks(context.Background(), "EURUSD"); err != nil {
		t.Fatal(err)
	}
	if err := ea.SendEvent("tick", map[string]any{"symbol": "EURUSD", "bid": 1.1, "ask": 1.2, "time_msc": 5}); err != nil {
		t.Fatal(err)
	}
	select {
	case tk := <-term.Ticks():
		if tk.Symbol != "EURUSD" || tk.Bid != 1.1 || tk.TimeMsc != 5 {
			t.Fatalf("tick %+v", tk)
		}
	case <-time.After(time.Second):
		t.Fatal("no tick delivered")
	}
}

func TestTickOverflowDropsNotBlocks(t *testing.T) {
	ea := mt5test.New(token)
	_, term := setup(t, mt5.Config{TickBuffer: 2}, ea)
	for i := 0; i < 5; i++ {
		_ = ea.SendEvent("tick", map[string]any{"symbol": "X", "time_msc": i})
	}
	// Responses must still flow even though nobody drains Ticks().
	if _, err := term.Ping(context.Background()); err != nil {
		t.Fatal(err)
	}
	if d := term.DroppedTicks(); d != 3 {
		t.Fatalf("dropped=%d want 3", d)
	}
}

func TestHeartbeatClosesDeadPeer(t *testing.T) {
	ea := mt5test.New(token)
	ea.Handlers["ping"] = func(map[string]any) (any, *protocol.Error) { return nil, mt5test.NoReply }
	_, term := setup(t, mt5.Config{PingInterval: 100 * time.Millisecond}, ea)
	select {
	case <-term.Done():
		if term.Err() == nil {
			t.Fatal("Err() nil after heartbeat failure")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("dead peer not detected")
	}
}

func TestMalformedFrameClosesTerminal(t *testing.T) {
	ea := mt5test.New(token)
	_, term := setup(t, mt5.Config{}, ea)
	_ = ea.SendRaw([]byte("not json"))
	select {
	case <-term.Done():
	case <-time.After(time.Second):
		t.Fatal("malformed frame did not close terminal")
	}
}

func TestConstantsMatchMQL5(t *testing.T) {
	// Spot-check generated values against documented MQL5 enum values.
	cases := map[string][2]int{
		"H1":         {int(mt5.TimeframeH1), 16385},
		"D1":         {int(mt5.TimeframeD1), 16408},
		"MN1":        {int(mt5.TimeframeMn1), 49153},
		"DONE":       {int(mt5.TradeRetcodeDone), 10009},
		"DEAL":       {int(mt5.TradeActionDeal), 1},
		"SELL_LIMIT": {int(mt5.OrderTypeSellLimit), 3},
	}
	for name, c := range cases {
		if c[0] != c[1] {
			t.Errorf("%s = %d, want %d", name, c[0], c[1])
		}
	}
}

func TestCloseDoesNotWaitForSilentHandshake(t *testing.T) {
	srv, err := mt5.Listen("127.0.0.1:0", mt5.Config{Token: token, HandshakeTimeout: 10 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	c, err := net.Dial("tcp", srv.Addr().String()) // connects, never sends hello
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	time.Sleep(100 * time.Millisecond)
	start := time.Now()
	srv.Close()
	if d := time.Since(start); d > time.Second {
		t.Fatalf("Close blocked %v on a silent handshake", d)
	}
}
