package record

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/condrove10/gomql5/mt5"
	"github.com/condrove10/gomql5/mt5/mt5test"
	"github.com/condrove10/gomql5/protocol"
)

// fakeAccount is a terminal whose account the test can change. As in a real
// login, the hello goes out before the account is known, so it says login=0.
type fakeAccount struct {
	mu        sync.Mutex
	login     int64
	server    string
	connected bool
	selectErr bool
}

func (f *fakeAccount) set(login int64, server string, connected bool) {
	f.mu.Lock()
	f.login, f.server, f.connected = login, server, connected
	f.mu.Unlock()
}

// dial connects a fresh EA and returns it with a channel that fires on subscribe.
func (f *fakeAccount) dial(t *testing.T, srv *mt5.Server) (*mt5test.FakeEA, chan struct{}) {
	t.Helper()
	ea := mt5test.New("tok")
	ea.Hello.Login, ea.Hello.Server, ea.Hello.Company = 0, "Hello-Server", "Hello Company"
	subscribed := make(chan struct{}, 8)
	ea.Handlers["account_info"] = func(map[string]any) (any, *protocol.Error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		return map[string]any{"login": f.login, "server": f.server, "company": "Poll Company", "trade_allowed": true,
			"name": "SECRET-HOLDER", "balance": 98765.25, "currency": "USD"}, nil
	}
	ea.Handlers["terminal_info"] = func(map[string]any) (any, *protocol.Error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		return map[string]any{"connected": f.connected, "build": 6300}, nil
	}
	ea.Handlers["symbol_select"] = func(map[string]any) (any, *protocol.Error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if f.selectErr {
			return nil, &protocol.Error{Code: -4, Message: "not found"}
		}
		return true, nil
	}
	ea.Handlers["symbol_info"] = func(map[string]any) (any, *protocol.Error) { return map[string]any{"name": "XAUUSD"}, nil }
	ea.Handlers["symbol_info_tick"] = func(map[string]any) (any, *protocol.Error) { return map[string]any{"bid": 1.0}, nil }
	ea.Handlers["symbols_get"] = func(map[string]any) (any, *protocol.Error) { return []string{}, nil }
	ea.Handlers["subscribe_ticks"] = func(map[string]any) (any, *protocol.Error) {
		select {
		case subscribed <- struct{}{}:
		default:
		}
		return true, nil
	}
	if err := ea.Dial(srv.Addr().String()); err != nil {
		t.Fatal(err)
	}
	return ea, subscribed
}

// startHealth runs a recorder with a fast health poll; stop ends it and closes the store.
func startHealth(t *testing.T) (dir string, r *Recorder, srv *mt5.Server, stop func()) {
	t.Helper()
	dir = t.TempDir()
	st, _ := Open(dir)
	srv, err := mt5.Listen("127.0.0.1:0", mt5.Config{Token: "tok", Logger: quiet()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { srv.Close() })
	r, _ = New(Config{Store: st, Log: quiet(), Server: srv, BrokerSymbol: "XAUUSD",
		FlushEvery: 10 * time.Millisecond, HealthEvery: 10 * time.Millisecond, ResyncQuiet: time.Hour})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- r.Run(ctx) }()
	var once sync.Once
	stop = func() {
		once.Do(func() {
			cancel()
			if err := <-done; err != nil {
				t.Error(err)
			}
			st.Close()
		})
	}
	t.Cleanup(stop) // a failed test still stops writing before TempDir is removed
	return dir, r, srv, stop
}

func waitUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func recvOrFail(t *testing.T, c chan struct{}) {
	t.Helper()
	select {
	case <-c:
	case <-time.After(3 * time.Second):
		t.Fatal("no subscribe")
	}
}

func eventsOf(evs []map[string]any, kind string) []map[string]any {
	var out []map[string]any
	for _, e := range evs {
		if e["kind"] == kind {
			out = append(out, e)
		}
	}
	return out
}

func sendTick(ea *mt5test.FakeEA, msc int64) {
	ea.SendEvent("tick", map[string]any{"symbol": "XAUUSD", "time_msc": msc, "bid": 4001.1, "ask": 4001.4})
}

// The hello says login=0 and the account arrives later: every record must
// carry what the poll says, not what the hello said.
func TestRecordsTakeAccountFromPollNotHello(t *testing.T) {
	dir, r, srv, stop := startHealth(t)
	f := &fakeAccount{}
	f.set(0, "", false)
	ea, sub := f.dial(t, srv)
	defer ea.Close()
	recvOrFail(t, sub)
	sendTick(ea, 1762268400100)
	waitUntil(t, "the first tick", func() bool { return r.Snapshot().Ticks == 1 })

	f.set(777001, "Broker-Live", true)
	waitUntil(t, "the poll to see the account", func() bool {
		s := r.Snapshot()
		return s.TerminalLogin == 777001 && s.TerminalServer == "Broker-Live" && s.TradeServerConnected
	})
	sendTick(ea, 1762268400200)
	waitUntil(t, "the second tick", func() bool { return r.Snapshot().Ticks == 2 })
	time.Sleep(50 * time.Millisecond) // many polls: must not repeat the account event
	stop()

	pr := readLines(t, filepath.Join(dir, "prices.jsonl"))
	if len(pr) != 2 {
		t.Fatalf("prices: %d %v", len(pr), pr)
	}
	if pr[1]["login"] != float64(777001) || pr[1]["broker_server"] != "Broker-Live" || pr[1]["broker_company"] != "Poll Company" ||
		pr[1]["trade_server_connected"] != true || pr[1]["conn"] != float64(1) || pr[1]["server_time"] != float64(1700000000) {
		t.Fatalf("record after the account arrived: %v", pr[1])
	}
	if pr[0]["login"] != float64(0) || pr[0]["broker_server"] != "" || pr[0]["trade_server_connected"] != false {
		t.Fatalf("record before the account arrived: %v", pr[0])
	}

	ev := readLines(t, filepath.Join(dir, "events.jsonl"))
	acct := eventsOf(ev, "account")
	if len(acct) != 2 {
		t.Fatalf("want one account event per distinct value, got %d: %v", len(acct), acct)
	}
	if acct[1]["login"] != float64(777001) || acct[1]["server"] != "Broker-Live" || acct[1]["company"] != "Poll Company" ||
		acct[1]["trade_allowed"] != true || acct[1]["conn"] != float64(1) {
		t.Fatalf("account event: %v", acct[1])
	}
	// Exactly these fields, plus the envelope every event has.
	var keys []string
	for k := range acct[1] {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	want := "at company conn id kind login run_id schema seq server trade_allowed"
	if got := strings.Join(keys, " "); got != want {
		t.Fatalf("account fields: %q, want %q", got, want)
	}
	// The bundle holds events.jsonl and prices.jsonl: no holder name, no money.
	for _, name := range []string{"events.jsonl", "prices.jsonl"} {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		for _, leak := range []string{"SECRET-HOLDER", "98765", `"name"`, `"balance"`} {
			if strings.Contains(string(b), leak) {
				t.Fatalf("%s contains %s", name, leak)
			}
		}
	}
	// The hello is recorded as what it was, and everything about the
	// connection says which connection.
	if tc := eventsOf(ev, "terminal_connected"); len(tc) != 1 || tc[0]["login"] != float64(0) || tc[0]["server"] != "Hello-Server" {
		t.Fatalf("terminal_connected: %v", tc)
	}
	for _, kind := range []string{"terminal_connected", "terminal_disconnected", "terminal_info", "instrument", "account"} {
		es := eventsOf(ev, kind)
		if len(es) == 0 {
			t.Fatalf("no %s event", kind)
		}
		for _, e := range es {
			if e["conn"] != float64(1) {
				t.Fatalf("%s without conn: %v", kind, e)
			}
		}
	}
	if ti := eventsOf(ev, "terminal_info"); ti[len(ti)-1]["login"] != float64(777001) {
		t.Fatalf("terminal_info login is not the poll's: %v", ti)
	}
	if in := eventsOf(ev, "terminal_disconnected"); in[0]["login"] != float64(777001) {
		t.Fatalf("terminal_disconnected login is not the poll's: %v", in)
	}
}

// A second connection is a new login: the same account must be written again,
// and its records and events must say conn 2, so a checker can read it alone.
func TestSecondConnectionWritesAccountAgain(t *testing.T) {
	dir, r, srv, stop := startHealth(t)
	f := &fakeAccount{}
	f.set(777001, "Broker-Live", true)
	ea, sub := f.dial(t, srv)
	recvOrFail(t, sub)
	sendTick(ea, 1762268400100)
	waitUntil(t, "the first tick", func() bool { return r.Snapshot().Ticks == 1 })
	ea.Close()
	waitUntil(t, "the disconnect", func() bool { return !r.Snapshot().TerminalConnected })

	ea2, sub2 := f.dial(t, srv)
	defer ea2.Close()
	recvOrFail(t, sub2)
	sendTick(ea2, 1762268400200)
	waitUntil(t, "the second tick", func() bool { return r.Snapshot().Ticks == 2 })
	time.Sleep(50 * time.Millisecond)
	stop()

	acct := eventsOf(readLines(t, filepath.Join(dir, "events.jsonl")), "account")
	if len(acct) != 2 || acct[0]["conn"] != float64(1) || acct[1]["conn"] != float64(2) {
		t.Fatalf("want one account event per connection, conn 1 then 2: %v", acct)
	}
	if acct[1]["login"] != float64(777001) {
		t.Fatalf("account on the second connection: %v", acct[1])
	}
	pr := readLines(t, filepath.Join(dir, "prices.jsonl"))
	if len(pr) != 2 || pr[0]["conn"] != float64(1) || pr[1]["conn"] != float64(2) {
		t.Fatalf("records must carry their connection: %v", pr)
	}
	ti := eventsOf(readLines(t, filepath.Join(dir, "events.jsonl")), "terminal_info")
	if len(ti) != 2 || ti[1]["conn"] != float64(2) {
		t.Fatalf("want one terminal_info per connection: %v", ti)
	}
}

// With the symbol unavailable the health poll still runs, so the trade-server
// phase is observed instead of reading "never".
func TestHealthPollRunsWhileSymbolUnavailable(t *testing.T) {
	dir, r, srv, stop := startHealth(t)
	f := &fakeAccount{selectErr: true}
	f.set(0, "", false)
	ea, _ := f.dial(t, srv)
	defer ea.Close()
	waitUntil(t, "the select error", func() bool { return r.Snapshot().LastError != "" })

	f.set(777001, "Broker-Live", true)
	waitUntil(t, "the poll to see the login", func() bool {
		s := r.Snapshot()
		return s.TerminalLogin == 777001 && s.TradeServerConnected
	})
	stop()

	ev := readLines(t, filepath.Join(dir, "events.jsonl"))
	ti := eventsOf(ev, "terminal_info")
	if len(ti) != 2 || ti[1]["trade_server_connected"] != true || ti[1]["conn"] != float64(1) {
		t.Fatalf("terminal_info while the symbol is unavailable: %v", ti)
	}
	acct := eventsOf(ev, "account")
	if len(acct) != 2 || acct[1]["login"] != float64(777001) {
		t.Fatalf("account while the symbol is unavailable: %v", acct)
	}
	q := eventsOf(ev, "quality")
	if len(q) == 0 || q[0]["conn"] != float64(1) {
		t.Fatalf("quality event without conn: %v", q)
	}
}

// An unanswered account_info must not invent an account: the records keep the
// hello's values and no account event is written, which fails L1 downstream.
func TestNoAccountEventWhenAccountInfoFails(t *testing.T) {
	dir, r, srv, stop := startHealth(t)
	ea := mt5test.New("tok")
	sub := make(chan struct{}, 8)
	ea.Handlers["symbol_select"] = func(map[string]any) (any, *protocol.Error) { return true, nil }
	ea.Handlers["subscribe_ticks"] = func(map[string]any) (any, *protocol.Error) { sub <- struct{}{}; return true, nil }
	if err := ea.Dial(srv.Addr().String()); err != nil {
		t.Fatal(err)
	}
	defer ea.Close()
	recvOrFail(t, sub)
	sendTick(ea, 1762268400100)
	waitUntil(t, "the tick", func() bool { return r.Snapshot().Ticks == 1 })
	stop()

	if acct := eventsOf(readLines(t, filepath.Join(dir, "events.jsonl")), "account"); len(acct) != 0 {
		t.Fatalf("account event without an answer: %v", acct)
	}
	pr := readLines(t, filepath.Join(dir, "prices.jsonl"))
	if len(pr) != 1 || pr[0]["login"] != float64(12345) || pr[0]["broker_server"] != "Demo-Server" || pr[0]["conn"] != float64(1) {
		t.Fatalf("record: %v", pr)
	}
}
