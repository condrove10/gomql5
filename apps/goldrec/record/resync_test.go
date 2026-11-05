package record

import (
	"context"
	"log/slog"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
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
	// FakeEA's default ping answers 1700000000 (seconds): the broker clock for the market-closed rule.
	if ev["server_time"] != float64(1700000000) {
		t.Fatalf("server_time not recorded (seconds, from Ping): %v", ev)
	}
	if pr := readLines(t, filepath.Join(dir, "prices.jsonl")); len(pr) == 0 {
		t.Fatal("ticks did not resume after the quiet resync")
	}
}

func TestCandidatesPattern(t *testing.T) {
	for sym, want := range map[string]string{"XAUUSD": "*XAU*,*GOLD*", "gold.m": "*XAU*,*GOLD*", "BTCUSD": "*BTC*",
		"btcusd.r": "*BTC*", "EURUSD": "*EUR*", "X": "*XAU*,*GOLD*"} {
		if got := candidatesPattern(sym); got != want {
			t.Errorf("%s: %q, want %q", sym, got, want)
		}
	}
}

// selectScript is an EA whose symbol_select and symbols_get answers the test
// decides per call. subscribed fires once the recorder subscribes.
func selectScript(sel func(call int) *protocol.Error, cands func() []string) (*mt5test.FakeEA, chan struct{}) {
	ea := mt5test.New("tok")
	subscribed := make(chan struct{}, 8)
	var mu sync.Mutex
	calls := 0
	ea.Handlers["symbol_select"] = func(map[string]any) (any, *protocol.Error) {
		mu.Lock()
		calls++
		n := calls
		mu.Unlock()
		if perr := sel(n); perr != nil {
			return nil, perr
		}
		return true, nil
	}
	ea.Handlers["symbols_get"] = func(map[string]any) (any, *protocol.Error) { return cands(), nil }
	ea.Handlers["symbol_info"] = func(map[string]any) (any, *protocol.Error) { return map[string]any{"name": "XAUUSD"}, nil }
	ea.Handlers["subscribe_ticks"] = func(map[string]any) (any, *protocol.Error) {
		subscribed <- struct{}{}
		return true, nil
	}
	return ea, subscribed
}

func unavailable(evs []map[string]any) []map[string]any {
	var out []map[string]any
	for _, e := range eventsOf(evs, "quality") {
		if e["what"] == "broker_symbol_unavailable" {
			out = append(out, e)
		}
	}
	return out
}

// A symbol the terminal refuses until after the sync: the select keeps failing
// past the 30 s the calls used to share, its first attempt hangs and must time
// out on its own, and then ticks flow on the same connection. Takes over 30 s
// of real time, because the old window was a real deadline.
func TestSymbolSelectRetriesAfterSync(t *testing.T) {
	t.Parallel()
	const window = 31 * time.Second
	dir, r, srv, stop := startRecorder(t, func(c *Config) { c.SelectRetry = 100 * time.Millisecond })
	start := time.Now()
	ea, subscribed := selectScript(func(call int) *protocol.Error {
		switch {
		case call == 1:
			return mt5test.NoReply
		case time.Since(start) < window:
			return &protocol.Error{Code: -4, Message: "symbol 'XAUUSD' not found"}
		}
		return nil
	}, func() []string { return []string{} })
	if err := ea.Dial(srv.Addr().String()); err != nil {
		t.Fatal(err)
	}
	defer ea.Close()

	select {
	case <-subscribed:
	case <-time.After(window + 10*time.Second):
		t.Fatalf("no subscribe %v after the connect; last error: %q", time.Since(start), r.Snapshot().LastError)
	}
	if took := time.Since(start); took < window {
		t.Fatalf("subscribed after %v, before the select could succeed", took)
	}
	if e := r.Snapshot().LastError; e != "" {
		t.Fatalf("error still in status after the select succeeded: %q", e)
	}
	sendTick(ea, 1762268400100)
	sendTick(ea, 1762268400200)
	waitUntil(t, "the ticks", func() bool { return r.Snapshot().Ticks == 2 })
	stop()

	ev := readLines(t, filepath.Join(dir, "events.jsonl"))
	if c := eventsOf(ev, "terminal_connected"); len(c) != 1 {
		t.Fatalf("terminal_connected %d times: the connection must survive the retries", len(c))
	}
	if i := eventsOf(ev, "instrument"); len(i) != 1 || i[0]["broker_symbol"] != "XAUUSD" {
		t.Fatalf("instrument after the late select: %v", i)
	}
	// The hung attempt, then "not found": hundreds of attempts, two answers.
	q := unavailable(ev)
	if len(q) != 2 || q[1]["error"] != "mt5 error -4: symbol 'XAUUSD' not found" {
		t.Fatalf("unavailable events: %v", q)
	}
}

// The event appears only when what it says changes: the same refusal is
// silent, and new candidates (the sync brought symbols in) are news.
func TestSymbolRetryEventOnlyOnChange(t *testing.T) {
	var mu sync.Mutex
	cands := []string{}
	failing := true
	dir, r, srv, stop := startRecorder(t, func(c *Config) { c.SelectRetry = 5 * time.Millisecond })
	var attempts atomic.Int64
	ea, subscribed := selectScript(func(call int) *protocol.Error {
		attempts.Store(int64(call))
		mu.Lock()
		defer mu.Unlock()
		if failing {
			return &protocol.Error{Code: -4, Message: "not found"}
		}
		return nil
	}, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return cands
	})
	if err := ea.Dial(srv.Addr().String()); err != nil {
		t.Fatal(err)
	}
	defer ea.Close()
	waitUntil(t, "several attempts", func() bool { return attempts.Load() >= 10 })
	mu.Lock()
	cands = []string{"GOLD.m"}
	mu.Unlock()
	seenAt := attempts.Load()
	waitUntil(t, "more attempts", func() bool { return attempts.Load() >= seenAt+10 })
	if e := r.Snapshot().LastError; !strings.Contains(e, "not found") {
		t.Fatalf("status during the retries: %q", e)
	}
	mu.Lock()
	failing = false
	mu.Unlock()
	recvOrFail(t, subscribed)
	sendTick(ea, 1762268400100) // read only once the subscribe has returned
	waitUntil(t, "the tick", func() bool { return r.Snapshot().Ticks == 1 })
	stop()

	q := unavailable(readLines(t, filepath.Join(dir, "events.jsonl")))
	if len(q) != 2 || len(toStrings(q[0]["candidates"])) != 0 || strings.Join(toStrings(q[1]["candidates"]), ",") != "GOLD.m" {
		t.Fatalf("unavailable events over %d attempts: %v", attempts.Load(), q)
	}
	if e := r.Snapshot().LastError; e != "" {
		t.Fatalf("error still in status: %q", e)
	}
}

// The retry ends with the connection, says nothing about the symbol while it
// does, and the next connection starts over.
func TestSymbolRetryEndsWithConnection(t *testing.T) {
	dir, r, srv, stop := startRecorder(t, func(c *Config) { c.SelectRetry = time.Millisecond })
	fail := func(int) *protocol.Error { return &protocol.Error{Code: -4, Message: "not found"} }
	first, _ := selectScript(fail, func() []string { return []string{} })
	if err := first.Dial(srv.Addr().String()); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, "the select error", func() bool { return r.Snapshot().LastError != "" })
	first.Close()
	waitUntil(t, "the disconnect", func() bool { return !r.Snapshot().TerminalConnected })

	second, subscribed := selectScript(func(int) *protocol.Error { return nil }, func() []string { return []string{} })
	if err := second.Dial(srv.Addr().String()); err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	recvOrFail(t, subscribed)
	sendTick(second, 1762268400100) // read only once the subscribe has returned
	waitUntil(t, "the tick", func() bool { return r.Snapshot().Ticks == 1 })
	stop()

	ev := readLines(t, filepath.Join(dir, "events.jsonl"))
	if d := eventsOf(ev, "terminal_disconnected"); len(d) < 1 || d[0]["conn"] != float64(1) {
		t.Fatalf("terminal_disconnected: %v", d)
	}
	q := unavailable(ev)
	if len(q) != 1 || q[0]["error"] != "mt5 error -4: not found" {
		t.Fatalf("unavailable events: %v", q)
	}
	if e := r.Snapshot().LastError; e != "" {
		t.Fatalf("error from the old connection still in status: %q", e)
	}
}
