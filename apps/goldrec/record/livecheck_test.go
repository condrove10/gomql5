package record

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	lcLogin  = int64(777001)
	lcServer = "Broker-Live"
	lcBase   = int64(1762268400000) // broker clock, ms
)

var lcT0 = time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)

// lcAt is lcT0 plus s seconds.
func lcAt(s float64) time.Time { return lcT0.Add(time.Duration(s * float64(time.Second))) }

func lcRunStart(run string) map[string]any {
	return map[string]any{"kind": "run_start", "run_id": run, "at": lcT0.Add(-time.Minute)}
}

func lcAccount(run string, conn uint64, s float64, login int64, server string) map[string]any {
	return map[string]any{"kind": "account", "run_id": run, "conn": conn, "at": lcAt(s),
		"login": login, "server": server, "company": "Poll Company", "trade_allowed": true}
}

func lcInfo(run string, conn uint64, s float64, connected bool) map[string]any {
	return map[string]any{"kind": "terminal_info", "run_id": run, "conn": conn, "at": lcAt(s),
		"trade_server_connected": connected, "build": 6300, "login": 0}
}

// lcTick is a record that passes everything: received s seconds after lcT0,
// with the broker clock moving at the same pace from lcBase.
func lcTick(run string, conn uint64, s float64) PriceRecord {
	msc := lcBase + int64(s*1000)
	return PriceRecord{RunID: run, Conn: conn, Login: lcLogin, Server: lcServer, TradeServerConnected: true,
		ProviderTimeMsc: msc, ReceivedAt: lcAt(s), ServerTime: msc / 1000}
}

func lcTicks(run string, conn uint64, secs ...float64) []PriceRecord {
	var out []PriceRecord
	for _, s := range secs {
		out = append(out, lcTick(run, conn, s))
	}
	return out
}

func lcWrite(t *testing.T, dir, name string, recs []any) {
	t.Helper()
	var b strings.Builder
	for _, r := range recs {
		line, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		b.Write(line)
		b.WriteByte('\n')
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}

func lcAnyEvents(in []map[string]any) []any {
	out := make([]any, len(in))
	for i, v := range in {
		out[i] = v
	}
	return out
}

func lcAnyPrices(in []PriceRecord) []any {
	out := make([]any, len(in))
	for i, v := range in {
		out[i] = v
	}
	return out
}

func lcHealthy(run string, conn uint64) []map[string]any {
	return []map[string]any{lcRunStart(run), lcAccount(run, conn, 0, lcLogin, lcServer), lcInfo(run, conn, 0, true)}
}

func TestCheckLiveRules(t *testing.T) {
	const r = "run1"
	// Each case changes one thing about a passing run.
	cases := []struct {
		name    string
		events  []map[string]any
		prices  []PriceRecord
		conn    uint64 // 1 unless set
		min     int    // 3 unless set
		nowS    float64
		reason  string
		rc      int
		waiting string
	}{
		{name: "pass", events: lcHealthy(r, 1), prices: lcTicks(r, 1, 1, 2, 3, 4), reason: "ok", rc: 0},
		{name: "L4: first record of the connection does not count", events: lcHealthy(r, 1), prices: lcTicks(r, 1, 1, 2, 3),
			reason: "pending", rc: 64, waiting: "ticks"},
		{name: "L4: one fresh record is enough when asked for one", events: lcHealthy(r, 1), prices: lcTicks(r, 1, 1, 2), min: 1, reason: "ok"},
		{name: "L4: only the first record, then silence", events: lcHealthy(r, 1), prices: lcTicks(r, 1, 1), min: 1,
			reason: "pending", rc: 64, waiting: "ticks"},
		{name: "L4: repeated provider time does not count", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].ProviderTimeMsc = p[2].ProviderTimeMsc
				return p
			}(), reason: "pending", rc: 64, waiting: "ticks"},
		{name: "L4: records received before the account event do not count",
			events: []map[string]any{lcRunStart(r), lcAccount(r, 1, 3, lcLogin, lcServer), lcInfo(r, 1, 3, true)},
			prices: lcTicks(r, 1, 1, 2, 3.5, 4), reason: "pending", rc: 64, waiting: "ticks"},
		{name: "L4: records naming another server do not count", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].Server = "MetaQuotes-Demo"
				return p
			}(), reason: "pending", rc: 64, waiting: "ticks"},
		{name: "L4: records naming another login do not count", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].Login = 1
				return p
			}(), reason: "pending", rc: 64, waiting: "ticks"},
		{name: "L1: no account event, however good the ticks",
			events: []map[string]any{lcRunStart(r), lcInfo(r, 1, 0, true)}, prices: lcTicks(r, 1, 1, 2, 3, 4),
			reason: "pending", rc: 64, waiting: "account"},
		{name: "L1: login 0 is a terminal that has not logged in yet",
			events: []map[string]any{lcRunStart(r), lcAccount(r, 1, 0, 0, ""), lcInfo(r, 1, 0, true)},
			prices: lcTicks(r, 1, 1, 2, 3, 4), nowS: 100, reason: "pending", rc: 64, waiting: "account"},
		{name: "L1: another login", events: []map[string]any{lcRunStart(r), lcAccount(r, 1, 0, 42, lcServer), lcInfo(r, 1, 0, true)},
			reason: "wrong_account", rc: 25},
		{name: "L1: the latest account decides",
			events: append(lcHealthy(r, 1), lcAccount(r, 1, 9, 42, lcServer)), prices: lcTicks(r, 1, 1, 2, 3, 4),
			reason: "wrong_account", rc: 25},
		{name: "L1: fallback server held too briefly to judge",
			events: []map[string]any{lcRunStart(r), lcAccount(r, 1, 0, lcLogin, "MetaQuotes-Demo"), lcInfo(r, 1, 0, true)},
			prices: lcTicks(r, 1, 1, 2, 3, 4), nowS: 14.9, reason: "pending", rc: 64, waiting: "account"},
		{name: "L1: fallback server held for 3 polls",
			events: []map[string]any{lcRunStart(r), lcAccount(r, 1, 0, lcLogin, "MetaQuotes-Demo"), lcInfo(r, 1, 0, true)},
			prices: lcTicks(r, 1, 1, 2, 3, 4), nowS: 15, reason: "fallback_server", rc: 22},
		{name: "L1: a late switch to the right server passes",
			events: []map[string]any{lcRunStart(r), lcAccount(r, 1, 0, lcLogin, "MetaQuotes-Demo"), lcAccount(r, 1, 0.5, lcLogin, lcServer), lcInfo(r, 1, 0, true)},
			prices: lcTicks(r, 1, 1, 2, 3, 4), nowS: 100, reason: "ok"},
		{name: "L1: moving between wrong servers does not restart the fallback hold",
			events: []map[string]any{lcRunStart(r), lcAccount(r, 1, 0, lcLogin, "MetaQuotes-Demo"), lcAccount(r, 1, 14, lcLogin, "MetaQuotes-Demo-2"), lcInfo(r, 1, 0, true)},
			nowS:   15, reason: "fallback_server", rc: 22},
		{name: "L2: no terminal_info yet", events: []map[string]any{lcRunStart(r), lcAccount(r, 1, 0, lcLogin, lcServer)},
			prices: lcTicks(r, 1, 1, 2, 3, 4), reason: "pending", rc: 64, waiting: "connected"},
		{name: "L2: not connected", events: []map[string]any{lcRunStart(r), lcAccount(r, 1, 0, lcLogin, lcServer), lcInfo(r, 1, 0, false)},
			prices: lcTicks(r, 1, 1, 2, 3, 4), reason: "pending", rc: 64, waiting: "connected"},
		{name: "L2: the latest terminal_info decides", events: append(lcHealthy(r, 1), lcInfo(r, 1, 9, false)),
			prices: lcTicks(r, 1, 1, 2, 3, 4), reason: "pending", rc: 64, waiting: "connected"},
		{name: "L2: cached quotes do not count", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].TradeServerConnected = false
				return p
			}(), reason: "pending", rc: 64, waiting: "ticks"},
		{name: "L5: 30 s of drift is tolerated", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].ProviderTimeMsc += 30000
				p[3].ServerTime = p[3].ProviderTimeMsc / 1000
				return p
			}(), reason: "ok"},
		{name: "L5: broker clock runs ahead of arrival", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].ProviderTimeMsc += 30001
				p[3].ServerTime = p[3].ProviderTimeMsc / 1000
				return p
			}(), reason: "stale_ticks", rc: 29},
		{name: "L5: arrival runs ahead of the broker clock", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].ReceivedAt = p[3].ReceivedAt.Add(30001 * time.Millisecond)
				return p
			}(), reason: "stale_ticks", rc: 29},
		{name: "L5: the pair with the dropped first record is not judged", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[0].ReceivedAt = p[0].ReceivedAt.Add(-time.Hour)
				return p
			}(), reason: "ok"},
		{name: "L5: the second accepted record is judged", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3)
				p[1].ProviderTimeMsc -= 60000
				return p
			}(), min: 2, reason: "stale_ticks", rc: 29},
		{name: "L6: exactly 300 s old", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].ServerTime = p[3].ProviderTimeMsc/1000 + 300
				return p
			}(), reason: "ok"},
		{name: "L6: rising but old", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].ServerTime = p[3].ProviderTimeMsc/1000 + 301
				return p
			}(), reason: "stale_ticks", rc: 29},
		{name: "L6: ahead of the server clock", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].ServerTime = p[3].ProviderTimeMsc/1000 - 301
				return p
			}(), reason: "stale_ticks", rc: 29},
		{name: "L6: no poll has answered Ping", events: lcHealthy(r, 1),
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].ServerTime = 0
				return p
			}(), reason: "pending", rc: 64, waiting: "server_time"},
		{name: "another connection's events and records do not count", conn: 2, events: lcHealthy(r, 1),
			prices: lcTicks(r, 1, 1, 2, 3, 4), reason: "pending", rc: 64, waiting: "account"},
		{name: "another connection's records do not count", conn: 2,
			events: append(lcHealthy(r, 1), lcAccount(r, 2, 0, lcLogin, lcServer), lcInfo(r, 2, 0, true)),
			prices: lcTicks(r, 1, 1, 2, 3, 4), reason: "pending", rc: 64, waiting: "ticks"},
		{name: "another connection's records do not fill this one", conn: 2,
			events: append(lcHealthy(r, 1), lcAccount(r, 2, 0, lcLogin, lcServer), lcInfo(r, 2, 0, true)),
			prices: append(lcTicks(r, 1, 1, 2), lcTicks(r, 2, 3, 4, 5)...), reason: "pending", rc: 64, waiting: "ticks"},
		{name: "another connection's account does not count", conn: 1,
			events: append(lcHealthy(r, 1), lcAccount(r, 2, 0, 42, lcServer)),
			prices: lcTicks(r, 1, 1, 2, 3, 4), reason: "ok"},
		{name: "an earlier run's events do not count",
			events: append(lcHealthy("old", 1), lcRunStart(r)), prices: lcTicks(r, 1, 1, 2, 3, 4),
			reason: "pending", rc: 64, waiting: "account"},
		{name: "an earlier run's records do not count",
			events: append(lcHealthy("old", 1), lcHealthy(r, 1)...), prices: lcTicks("old", 1, 1, 2, 3, 4),
			reason: "pending", rc: 64, waiting: "ticks"},
		{name: "restart: first accepted above the last value before it", conn: 2,
			events: append(lcHealthy(r, 1), lcAccount(r, 2, 0, lcLogin, lcServer), lcInfo(r, 2, 0, true)),
			prices: append(lcTicks(r, 1, 1, 2), lcTicks(r, 2, 3, 4, 5, 6)...), reason: "ok"},
		{name: "restart: first accepted not above the last value before it", conn: 2,
			events: append(lcHealthy(r, 1), lcAccount(r, 2, 0, lcLogin, lcServer), lcInfo(r, 2, 0, true)),
			prices: append(lcTicks(r, 1, 1, 9), lcTicks(r, 2, 3, 4, 5, 6)...), reason: "stale_ticks", rc: 29},
		{name: "restart: an earlier run sets no floor",
			events: append(lcHealthy("old", 1), lcHealthy(r, 2)...), conn: 2,
			prices: append(lcTicks("old", 1, 100), lcTicks(r, 2, 1, 2, 3, 4)...), reason: "ok"},
		{name: "identity comes before freshness",
			events: []map[string]any{lcRunStart(r), lcAccount(r, 1, 0, 42, lcServer), lcInfo(r, 1, 0, true)},
			prices: func() []PriceRecord {
				p := lcTicks(r, 1, 1, 2, 3, 4)
				p[3].ProviderTimeMsc += 60000
				return p
			}(), reason: "wrong_account", rc: 25},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			lcWrite(t, dir, "events.jsonl", lcAnyEvents(c.events))
			lcWrite(t, dir, "prices.jsonl", lcAnyPrices(c.prices))
			conn, min := c.conn, c.min
			if conn == 0 {
				conn = 1
			}
			if min == 0 {
				min = 3
			}
			got := CheckLive(LiveCheck{Dir: dir, ExpectLogin: lcLogin, ExpectServer: lcServer, MinFresh: min, Conn: conn,
				Now: func() time.Time { return lcAt(c.nowS) }})
			if got.Reason != c.reason || got.RC != c.rc || got.Waiting != c.waiting {
				t.Fatalf("got %q (rc %d), want reason=%s rc=%d waiting=%q", got, got.RC, c.reason, c.rc, c.waiting)
			}
			if !strings.HasPrefix(got.String(), "reason="+c.reason) {
				t.Fatalf("line must begin with the reason: %q", got)
			}
		})
	}
}

// The line goes into logs and the bundle, and carries enough to act on.
func TestCheckLiveLine(t *testing.T) {
	dir := t.TempDir()
	lcWrite(t, dir, "events.jsonl", lcAnyEvents([]map[string]any{lcRunStart("r"), lcAccount("r", 1, 0, 42, lcServer), lcInfo("r", 1, 0, true)}))
	check := LiveCheck{Dir: dir, ExpectLogin: lcLogin, ExpectServer: lcServer, MinFresh: 3, Conn: 1}
	got := CheckLive(check).String()
	for _, leak := range []string{"42", fmt.Sprint(lcLogin)} {
		if strings.Contains(got, leak) {
			t.Fatalf("login in the line: %q", got)
		}
	}

	lcWrite(t, dir, "events.jsonl", lcAnyEvents(lcHealthy("r", 1)))
	lcWrite(t, dir, "prices.jsonl", lcAnyPrices(lcTicks("r", 1, 1, 2)))
	if got := CheckLive(check).String(); got != "reason=pending conn=1 records=2 fresh=1/3 waiting=ticks" {
		t.Fatalf("pending line: %q", got)
	}
	p := lcTicks("r", 1, 1, 2, 3, 4)
	p[3].ServerTime += 400
	lcWrite(t, dir, "prices.jsonl", lcAnyPrices(p))
	if got := CheckLive(check).String(); got != "reason=stale_ticks conn=1 records=4 fresh=3/3 last_tick_age_ms=400000" {
		t.Fatalf("stale line: %q", got)
	}
	lcWrite(t, dir, "prices.jsonl", lcAnyPrices(lcTicks("r", 1, 1, 2, 3, 4)))
	if got := CheckLive(check).String(); got != `reason=ok conn=1 records=4 fresh=3/3 last_tick_age_ms=0 server="Broker-Live" company="Poll Company"` {
		t.Fatalf("ok line: %q", got)
	}
}

func TestCheckLiveArguments(t *testing.T) {
	good := LiveCheck{Dir: t.TempDir(), ExpectLogin: lcLogin, ExpectServer: lcServer, MinFresh: 3, Conn: 1}
	for _, c := range []struct {
		name   string
		change func(*LiveCheck)
		reason string
		rc     int
	}{
		{"no login", func(l *LiveCheck) { l.ExpectLogin = 0 }, "env_missing", 10},
		{"no server", func(l *LiveCheck) { l.ExpectServer = "" }, "expect_server_missing", 12},
		{"no connection", func(l *LiveCheck) { l.Conn = 0 }, "unclassified", 1},
		{"no count", func(l *LiveCheck) { l.MinFresh = 0 }, "unclassified", 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			l := good
			c.change(&l)
			if got := CheckLive(l); got.Reason != c.reason || got.RC != c.rc {
				t.Fatalf("got %q rc %d", got, got.RC)
			}
		})
	}
}

// The recorder is still writing while this reads, and nothing has to exist yet.
func TestCheckLiveReadsPartialData(t *testing.T) {
	check := LiveCheck{ExpectLogin: lcLogin, ExpectServer: lcServer, MinFresh: 3, Conn: 1}

	t.Run("no directory", func(t *testing.T) {
		check := check
		check.Dir = filepath.Join(t.TempDir(), "absent")
		if got := CheckLive(check); got.Reason != "pending" || got.RC != 64 {
			t.Fatalf("got %q", got)
		}
		if _, err := os.Stat(check.Dir); !os.IsNotExist(err) {
			t.Fatalf("the check must not create the directory: %v", err)
		}
	})
	t.Run("a line still being written is not read", func(t *testing.T) {
		check := check
		check.Dir = t.TempDir()
		lcWrite(t, check.Dir, "events.jsonl", lcAnyEvents(lcHealthy("r", 1)))
		lcWrite(t, check.Dir, "prices.jsonl", lcAnyPrices(lcTicks("r", 1, 1, 2, 3, 4)))
		f, err := os.OpenFile(filepath.Join(check.Dir, "prices.jsonl"), os.O_APPEND|os.O_WRONLY, 0)
		if err != nil {
			t.Fatal(err)
		}
		f.WriteString(`{"run_id":"r","conn":1,"provider_ti`)
		f.Close()
		if got := CheckLive(check); got.Reason != "ok" {
			t.Fatalf("got %q", got)
		}
	})
	for _, name := range []string{"events.jsonl", "prices.jsonl"} {
		t.Run("a broken line in "+name+" is not skipped", func(t *testing.T) {
			check := check
			check.Dir = t.TempDir()
			lcWrite(t, check.Dir, "events.jsonl", lcAnyEvents(lcHealthy("r", 1)))
			lcWrite(t, check.Dir, "prices.jsonl", lcAnyPrices(lcTicks("r", 1, 1, 2, 3, 4)))
			f, err := os.OpenFile(filepath.Join(check.Dir, name), os.O_APPEND|os.O_WRONLY, 0)
			if err != nil {
				t.Fatal(err)
			}
			f.WriteString("{broken\n")
			f.Close()
			got := CheckLive(check)
			if got.Reason != "unclassified" || got.RC != 1 || !strings.Contains(got.String(), name) {
				t.Fatalf("got %q rc %d", got, got.RC)
			}
		})
	}
}

// One run through the recorder, so the check reads what it really writes: a
// login=0 hello, a cached first tick, the account arriving late, a restart,
// then the terminal falling back and changing account.
func TestCheckLiveThroughRecorder(t *testing.T) {
	const tick = int64(1700000000000) // FakeEA's Ping says 1700000000 s
	dir, r, srv, stop := startHealth(t)
	check := func(conn uint64) LiveResult {
		return CheckLive(LiveCheck{Dir: dir, ExpectLogin: lcLogin, ExpectServer: lcServer, MinFresh: 3, Conn: conn})
	}
	want := func(got LiveResult, reason, waiting string) {
		t.Helper()
		if got.Reason != reason || got.Waiting != waiting {
			t.Fatalf("got %q, want reason=%s waiting=%q", got, reason, waiting)
		}
	}
	ticks := func(n uint64) { waitUntil(t, "the ticks", func() bool { return r.Snapshot().Ticks == n }) }

	f := &fakeAccount{}
	f.set(0, "", false)
	ea, sub := f.dial(t, srv)
	recvOrFail(t, sub)
	sendTick(ea, tick+100) // the cached quote the EA sends first
	ticks(1)
	waitUntil(t, "the first record on disk", func() bool { return check(1).Records == 1 })
	want(check(1), "pending", "account")

	f.set(lcLogin, lcServer, true)
	waitUntil(t, "identity", func() bool { // the event goes out just before the state it announces
		s := r.Snapshot()
		return check(1).Waiting == "ticks" && s.TerminalLogin == lcLogin && s.TradeServerConnected
	})
	sendTick(ea, tick+200)
	sendTick(ea, tick+300)
	ticks(3)
	waitUntil(t, "two fresh records", func() bool { return check(1).Fresh == 2 })
	want(check(1), "pending", "ticks")
	sendTick(ea, tick+400)
	waitUntil(t, "L1, L2, L4, L5, L6", func() bool { return check(1).Reason == "ok" })

	// The restart: conn 2 has its own login and its own first record, whatever
	// conn 1 proved.
	ea.Close()
	waitUntil(t, "the disconnect", func() bool { return !r.Snapshot().TerminalConnected })
	ea2, sub2 := f.dial(t, srv)
	defer ea2.Close()
	recvOrFail(t, sub2)
	waitUntil(t, "identity on conn 2", func() bool { return check(2).Waiting == "ticks" })
	want(check(2), "pending", "ticks")
	for i := int64(5); i <= 7; i++ {
		sendTick(ea2, tick+i*100)
	}
	ticks(7)
	waitUntil(t, "three records on conn 2", func() bool { return check(2).Records == 3 })
	want(check(2), "pending", "ticks")
	sendTick(ea2, tick+800)
	waitUntil(t, "L1, L2, L4, L5, L6 on conn 2", func() bool { return check(2).Reason == "ok" })

	// Identity beats perfect ticks, read from real account events.
	f.set(lcLogin, "MetaQuotes-Demo", true)
	waitUntil(t, "the fallback held briefly", func() bool { return check(2).Waiting == "account" })
	got := CheckLive(LiveCheck{Dir: dir, ExpectLogin: lcLogin, ExpectServer: lcServer, MinFresh: 3, Conn: 2,
		Now: func() time.Time { return time.Now().Add(16 * time.Second) }})
	want(got, "fallback_server", "")
	f.set(42, lcServer, true)
	waitUntil(t, "the other account", func() bool { return check(2).Reason == "wrong_account" })
	stop()

	want(check(1), "ok", "") // conn 1 is unaffected by what happened on conn 2
}
