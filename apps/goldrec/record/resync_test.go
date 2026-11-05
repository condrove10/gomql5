package record

import (
	"context"
	"log/slog"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/condrove10/gomql5/mt5"
	"github.com/condrove10/gomql5/mt5/mt5test"
	"github.com/condrove10/gomql5/protocol"
)

// fakeAccountTerminal imitates the terminal around a login: it starts
// without a trade server; "login()" connects it and, like the account sync
// seen on the user's FTMO run, drops the symbol from Market Watch. Like the
// real EA's PollTicks (SymbolInfoTick fails → silently skipped), it streams
// ticks only while the symbol is selected.
type fakeAccountTerminal struct {
	mu        sync.Mutex
	connected bool
	selected  bool
	selects   int
	quoteMsc  int64
}

func (f *fakeAccountTerminal) handlers(ea *mt5test.FakeEA) {
	ea.Handlers["symbol_select"] = func(map[string]any) (any, *protocol.Error) {
		f.mu.Lock()
		f.selected = true
		f.selects++
		f.mu.Unlock()
		return true, nil
	}
	ea.Handlers["symbol_info"] = func(map[string]any) (any, *protocol.Error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		return map[string]any{"name": "XAUUSD", "select": f.selected, "path": "Metals\\XAUUSD"}, nil
	}
	ea.Handlers["symbol_info_tick"] = func(map[string]any) (any, *protocol.Error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		return map[string]any{"bid": 4001.1, "ask": 4001.4, "time_msc": f.quoteMsc}, nil
	}
	ea.Handlers["terminal_info"] = func(map[string]any) (any, *protocol.Error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		return map[string]any{"connected": f.connected, "build": 6300}, nil
	}
	ea.Handlers["subscribe_ticks"] = func(map[string]any) (any, *protocol.Error) { return true, nil }
}

func (f *fakeAccountTerminal) login() {
	f.mu.Lock()
	f.connected, f.selected = true, false // sync rebuilds Market Watch
	f.mu.Unlock()
}

// stream pushes a tick every 20 ms while the symbol is selected.
func (f *fakeAccountTerminal) stream(ctx context.Context, ea *mt5test.FakeEA) {
	msc := int64(1762300000000)
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(20 * time.Millisecond):
		}
		f.mu.Lock()
		on := f.selected && f.connected
		f.mu.Unlock()
		if on {
			msc += 100
			ea.SendEvent("tick", map[string]any{"symbol": "XAUUSD", "bid": 4001.2, "ask": 4001.5, "time_msc": msc})
		}
	}
}

func runResync(t *testing.T, quiet time.Duration, setup func(*fakeAccountTerminal), during func(*fakeAccountTerminal)) (string, *fakeAccountTerminal) {
	t.Helper()
	dir := t.TempDir()
	st, _ := Open(dir)
	srv, err := mt5.Listen("127.0.0.1:0", mt5.Config{Token: "tok", Logger: quiet0()})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	r, _ := New(Config{Store: st, Log: quiet0(), Server: srv, BrokerSymbol: "XAUUSD",
		FlushEvery: 20 * time.Millisecond, HealthEvery: 50 * time.Millisecond, ResyncQuiet: quiet})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- r.Run(ctx) }()

	f := &fakeAccountTerminal{}
	setup(f)
	ea := mt5test.New("tok")
	f.handlers(ea)
	if err := ea.Dial(srv.Addr().String()); err != nil {
		t.Fatal(err)
	}
	sctx, scancel := context.WithCancel(context.Background())
	go f.stream(sctx, ea)
	time.Sleep(200 * time.Millisecond) // subscribed, not yet logged in
	during(f)
	time.Sleep(600 * time.Millisecond)
	scancel()
	cancel()
	<-done
	ea.Close()
	st.Close()
	return dir, f
}

func quiet0() *slog.Logger { return quiet() }

// The user's FTMO sequence: subscribe, then the login/sync drops the symbol.
// Without a resync no tick ever arrives; with it, live ticks are recorded.
func TestResyncAfterLoginRestoresTicks(t *testing.T) {
	dir, f := runResync(t, time.Hour, // quiet resync disabled: only the connect transition
		func(f *fakeAccountTerminal) {},
		func(f *fakeAccountTerminal) { f.login() })
	pr := readLines(t, filepath.Join(dir, "prices.jsonl"))
	if len(pr) == 0 {
		t.Fatalf("no ticks after the login dropped the symbol (selects=%d)", f.selects)
	}
	if pr[0]["trade_server_connected"] != true {
		t.Fatalf("first tick not marked live: %v", pr[0])
	}
	found := false
	for _, e := range readLines(t, filepath.Join(dir, "events.jsonl")) {
		if e["kind"] == "symbol_resync" && e["reason"] == "trade_server_connected" && e["selected"] == true {
			found = true
		}
	}
	if !found {
		t.Fatal("no symbol_resync event (reason trade_server_connected, selected true)")
	}
}

// Connected all along but silent (e.g. the symbol was deselected some other
// way, or the market is closed): after ResyncQuiet the recorder re-selects
// and records the terminal's quote, whose old time shows a closed market.
func TestResyncWhenConnectedButQuiet(t *testing.T) {
	dir, _ := runResync(t, 150*time.Millisecond,
		func(f *fakeAccountTerminal) { f.connected = true; f.quoteMsc = 1762200000000 },
		func(f *fakeAccountTerminal) {
			f.mu.Lock()
			f.selected = false // dropped behind our back; no ticks now
			f.mu.Unlock()
		})
	var ev map[string]any
	for _, e := range readLines(t, filepath.Join(dir, "events.jsonl")) {
		if e["kind"] == "symbol_resync" && e["reason"] == "no_ticks" {
			ev = e
		}
	}
	if ev == nil {
		t.Fatal("no symbol_resync event with reason no_ticks")
	}
	if ev["quote_time_msc"] != float64(1762200000000) || ev["quote_broker_wallclock"] != "2025-11-03T20:00:00.000" {
		t.Fatalf("quote not recorded: %v", ev)
	}
	if pr := readLines(t, filepath.Join(dir, "prices.jsonl")); len(pr) == 0 {
		t.Fatal("ticks did not resume after the quiet resync")
	}
}
