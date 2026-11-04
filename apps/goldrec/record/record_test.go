package record

import (
	"bufio"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/condrove10/gomql5/apps/goldrec/myfxbook"
	"github.com/condrove10/gomql5/mt5"
	"github.com/condrove10/gomql5/mt5/mt5test"
	"github.com/condrove10/gomql5/protocol"
)

const fixtures = "../myfxbook/testdata/"

func readLines(t *testing.T, path string) []map[string]any {
	t.Helper()
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out []map[string]any
	sc := bufio.NewScanner(f)
	sc.Buffer(nil, 1<<20)
	for sc.Scan() {
		var m map[string]any
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			t.Fatalf("%s: bad line %q: %v", path, sc.Text(), err)
		}
		out = append(out, m)
	}
	return out
}

func quiet() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func TestReplayPollsRecordEverythingLabelled(t *testing.T) {
	dir := t.TempDir()
	st, _ := Open(dir)
	src := &Replay{Files: []string{fixtures + "synthetic-outlook-ok.json", fixtures + "synthetic-outlook-ok.json",
		fixtures + "synthetic-outlook-changed.json", fixtures + "synthetic-outlook-quirks.json"}}
	r, err := New(Config{Store: st, Log: quiet(), Source: src, SourceMode: "replay", Interval: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 4; i++ {
		if err := r.PollOnce(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	st.Close()

	att := readLines(t, filepath.Join(dir, "attempts.jsonl"))
	sen := readLines(t, filepath.Join(dir, "sentiment.jsonl"))
	qua := readLines(t, filepath.Join(dir, "quarantine.jsonl"))
	if len(att) != 4 || len(sen) != 3 || len(qua) != 1 {
		t.Fatalf("attempts=%d sentiment=%d quarantine=%d", len(att), len(sen), len(qua))
	}
	// Identical consecutive responses are both kept, the second marked same.
	if sen[0]["same_as_previous"] != nil || sen[1]["same_as_previous"] != true || sen[2]["same_as_previous"] != false {
		t.Fatalf("same_as_previous: %v %v %v", sen[0]["same_as_previous"], sen[1]["same_as_previous"], sen[2]["same_as_previous"])
	}
	ids := map[any]bool{}
	for _, s := range sen {
		if s["source_mode"] != "replay" || s["provider_time"] != nil || s["instrument"] != "XAUUSD" {
			t.Fatalf("labels: %v", s)
		}
		if ids[s["id"]] {
			t.Fatalf("duplicate id %v", s["id"])
		}
		ids[s["id"]] = true
		// raw_ref resolves to the exact body.
		f, err := os.Open(filepath.Join(dir, s["raw_ref"].(string)))
		if err != nil {
			t.Fatal(err)
		}
		zr, _ := gzip.NewReader(f)
		b, _ := io.ReadAll(zr)
		f.Close()
		resp, err := myfxbook.Parse(b)
		if err != nil || len(resp.Find("XAUUSD")) != 1 {
			t.Fatalf("raw ref does not hold the response: %v", err)
		}
		lv := s["supplied"].(map[string]any)["longVolume"]
		if !strings.Contains(string(b), `"longVolume":`+lv.(string)) {
			t.Fatalf("supplied %v not verbatim in raw body", lv)
		}
	}
	if sen[0]["raw_ref"] != sen[1]["raw_ref"] {
		t.Fatal("identical bodies should share one raw object")
	}
	if qua[0]["quarantined"] != true {
		t.Fatal("quarantine record not flagged")
	}
	if s := r.Snapshot(); s.Observations != 3 || s.Quarantined != 1 || s.AttemptsByStatus["ok"] != 4 {
		t.Fatalf("status %+v", s)
	}
}

type failingSource struct{}

func (failingSource) Fetch(context.Context) ([]myfxbook.Attempt, *myfxbook.Response) {
	now := time.Now().UTC()
	return []myfxbook.Attempt{{Method: "outlook", Start: now, End: now, Status: myfxbook.StatusHTTP, HTTPStatus: 403,
		Message: "Forbidden (Cloudflare challenge page)"}}, nil
}

func TestFailedAttemptsRecordedNoObservation(t *testing.T) {
	dir := t.TempDir()
	st, _ := Open(dir)
	r, _ := New(Config{Store: st, Log: quiet(), Source: failingSource{}, Interval: time.Second})
	r.PollOnce(context.Background())
	st.Close()
	if a := readLines(t, filepath.Join(dir, "attempts.jsonl")); len(a) != 1 || a[0]["status"] != "http_error" {
		t.Fatalf("%v", a)
	}
	if s := readLines(t, filepath.Join(dir, "sentiment.jsonl")); len(s) != 0 {
		t.Fatal("a failed attempt must not produce an observation")
	}
}

// TestPricesFromFakeEA runs the whole recorder against a FakeEA: symbol
// selection, metadata event, tick subscription, tick records, reconnect.
func TestPricesFromFakeEA(t *testing.T) {
	dir := t.TempDir()
	st, _ := Open(dir)
	srv, err := mt5.Listen("127.0.0.1:0", mt5.Config{Token: "tok", Logger: quiet()})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	src := &Replay{Files: []string{fixtures + "synthetic-outlook-ok.json"}}
	r, _ := New(Config{Store: st, Log: quiet(), Source: src, SourceMode: "replay", Interval: 50 * time.Millisecond,
		Server: srv, BrokerSymbol: "GOLD", FlushEvery: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- r.Run(ctx) }()

	newEA := func() (*mt5test.FakeEA, chan struct{}) {
		ea := mt5test.New("tok")
		subscribed := make(chan struct{})
		ea.Handlers["symbol_select"] = func(p map[string]any) (any, *protocol.Error) {
			if p["symbol"] != "GOLD" {
				return nil, &protocol.Error{Code: -4, Message: "not found"}
			}
			return true, nil
		}
		ea.Handlers["symbol_info"] = func(map[string]any) (any, *protocol.Error) {
			return map[string]any{"name": "GOLD", "digits": 2, "trade_contract_size": 100, "currency_profit": "USD"}, nil
		}
		ea.Handlers["terminal_info"] = func(map[string]any) (any, *protocol.Error) {
			return map[string]any{"connected": true, "build": 5000}, nil
		}
		ea.Handlers["subscribe_ticks"] = func(map[string]any) (any, *protocol.Error) { close(subscribed); return true, nil }
		if err := ea.Dial(srv.Addr().String()); err != nil {
			t.Fatal(err)
		}
		return ea, subscribed
	}
	send := func(ea *mt5test.FakeEA, msc int64, bid float64) {
		ea.SendEvent("tick", map[string]any{"symbol": "GOLD", "time": msc / 1000, "time_msc": msc, "bid": bid, "ask": bid + 0.3, "flags": 6})
	}
	ea, sub := newEA()
	<-sub
	send(ea, 1762268400123, 4001.10)
	send(ea, 1762268400456, 4001.20)
	ea.SendEvent("tick", map[string]any{"symbol": "EURUSD", "time_msc": 1, "bid": 1.1}) // other symbol: ignored
	time.Sleep(100 * time.Millisecond)
	ea.Close()

	// The EA reconnects: subscription must be re-issued and recording resumes.
	ea2, sub2 := newEA()
	select {
	case <-sub2:
	case <-time.After(2 * time.Second):
		t.Fatal("no re-subscribe after reconnect")
	}
	send(ea2, 1762268401000, 4001.30)
	time.Sleep(150 * time.Millisecond)
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	ea2.Close()
	st.Close()

	pr := readLines(t, filepath.Join(dir, "prices.jsonl"))
	if len(pr) != 3 {
		t.Fatalf("prices: %d %v", len(pr), pr)
	}
	if pr[0]["broker_symbol"] != "GOLD" || pr[0]["instrument"] != "XAUUSD" || pr[0]["provider_time_msc"] != float64(1762268400123) ||
		pr[0]["provider_time_broker_wallclock"] != "2025-11-04T15:00:00.123" || pr[2]["bid"] != 4001.3 || pr[0]["trade_server_connected"] != true {
		t.Fatalf("price record: %v", pr[0])
	}
	ev := readLines(t, filepath.Join(dir, "events.jsonl"))
	kinds := map[string]int{}
	for _, e := range ev {
		kinds[e["kind"].(string)]++
	}
	if kinds["terminal_connected"] != 2 || kinds["terminal_disconnected"] < 1 || kinds["instrument"] != 2 || kinds["run_start"] != 1 || kinds["run_stop"] != 1 {
		t.Fatalf("events: %v", kinds)
	}
	if sen := readLines(t, filepath.Join(dir, "sentiment.jsonl")); len(sen) < 2 {
		t.Fatalf("positioning loop did not keep polling alongside prices: %d", len(sen))
	}
	var s Status
	b, _ := os.ReadFile(filepath.Join(dir, "status.json"))
	json.Unmarshal(b, &s)
	if s.Ticks != 3 || s.RunID != r.RunID() {
		t.Fatalf("status.json: %+v", s)
	}
}

func TestWrongBrokerSymbolReportsCandidates(t *testing.T) {
	dir := t.TempDir()
	st, _ := Open(dir)
	srv, _ := mt5.Listen("127.0.0.1:0", mt5.Config{Token: "tok", Logger: quiet()})
	defer srv.Close()
	r, _ := New(Config{Store: st, Log: quiet(), Server: srv, BrokerSymbol: "XAUUSD"})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- r.Run(ctx) }()
	ea := mt5test.New("tok")
	ea.Handlers["symbol_select"] = func(map[string]any) (any, *protocol.Error) {
		return nil, &protocol.Error{Code: -4, Message: "symbol 'XAUUSD' not found"}
	}
	ea.Handlers["symbols_get"] = func(map[string]any) (any, *protocol.Error) { return []string{"GOLD.m"}, nil }
	ea.Dial(srv.Addr().String())
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && r.Snapshot().LastError == "" {
		time.Sleep(10 * time.Millisecond)
	}
	ea.Close()
	cancel()
	<-done
	st.Close()
	found := false
	for _, e := range readLines(t, filepath.Join(dir, "events.jsonl")) {
		if e["what"] == "broker_symbol_unavailable" && strings.Contains(strings.Join(toStrings(e["candidates"]), ","), "GOLD.m") {
			found = true
		}
	}
	if !found {
		t.Fatal("no broker_symbol_unavailable event with candidates")
	}
}

func toStrings(v any) []string {
	var out []string
	if a, ok := v.([]any); ok {
		for _, x := range a {
			out = append(out, x.(string))
		}
	}
	return out
}

func TestStoreFailureStopsRecorder(t *testing.T) {
	dir := t.TempDir()
	st, _ := Open(dir)
	r, _ := New(Config{Store: st, Log: quiet(), Source: &Replay{Files: []string{fixtures + "synthetic-outlook-ok.json"}},
		SourceMode: "replay", Interval: 10 * time.Millisecond})
	// Make the raw archive unwritable: PollOnce must return an error, and Run must stop.
	os.RemoveAll(filepath.Join(dir, "raw"))
	os.WriteFile(filepath.Join(dir, "raw"), []byte("not a dir"), 0o644)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := r.Run(ctx); err == nil || ctx.Err() != nil {
		t.Fatalf("want store error before timeout, got %v", err)
	}
}

func TestPriceInstrumentNeverMislabelled(t *testing.T) {
	for sym, want := range map[string]string{"XAUUSD": "XAUUSD", "XAUUSD.r": "XAUUSD", "GOLD": "XAUUSD", "gold.m": "XAUUSD",
		"EURUSD": "EURUSD", "XAUEUR": "XAUEUR"} {
		st, _ := Open(t.TempDir())
		srv, _ := mt5.Listen("127.0.0.1:0", mt5.Config{Token: "tok", Logger: quiet()})
		r, err := New(Config{Store: st, Server: srv, BrokerSymbol: sym})
		srv.Close()
		if err != nil {
			t.Fatal(err)
		}
		if r.cfg.PriceInstrument != want {
			t.Errorf("%s: price instrument %s, want %s", sym, r.cfg.PriceInstrument, want)
		}
	}
}

// Shutdown must not wait for the EA to disconnect, even in the
// "symbol unavailable" idle state.
func TestShutdownWithWrongSymbolWhileConnected(t *testing.T) {
	st, _ := Open(t.TempDir())
	srv, _ := mt5.Listen("127.0.0.1:0", mt5.Config{Token: "tok", Logger: quiet()})
	defer srv.Close()
	r, _ := New(Config{Store: st, Log: quiet(), Server: srv, BrokerSymbol: "XAUUSD"})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- r.Run(ctx) }()
	ea := mt5test.New("tok")
	ea.Handlers["symbol_select"] = func(map[string]any) (any, *protocol.Error) {
		return nil, &protocol.Error{Code: -4, Message: "not found"}
	}
	ea.Dial(srv.Addr().String())
	defer ea.Close()
	for i := 0; i < 200 && r.Snapshot().LastError == ""; i++ {
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after cancel while the EA stayed connected")
	}
}
