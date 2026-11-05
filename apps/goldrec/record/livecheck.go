package record

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

const (
	// liveFallbackHold is how long the expected login must stay on another
	// server before that is a fallback: 3 polls at the default HealthEvery,
	// because a late switch of server has not been ruled out.
	liveFallbackHold = 15 * time.Second
	// livePaceMsc is how far the broker clock and the arrival times may drift
	// apart between two accepted records (L5).
	livePaceMsc = int64(30_000)
	// liveMaxAgeMsc is how far the last accepted tick may be from the server's
	// clock (L6).
	liveMaxAgeMsc = int64(300_000)
)

// LiveCheck says what one run of CheckLive looks at and expects.
type LiveCheck struct {
	Dir          string
	ExpectLogin  int64
	ExpectServer string
	MinFresh     int
	Conn         uint64
	Now          func() time.Time // default time.Now
}

// LiveResult is the verdict. Reason and RC come from the live e2e's exit table,
// plus pending (64); Waiting says, for pending only, which rule is still open:
// account, connected, ticks or server_time.
type LiveResult struct {
	Reason   string
	RC       int
	Conn     uint64
	Records  int // this connection's records, the dropped first one included
	Fresh    int // accepted records
	MinFresh int
	Waiting  string
	detail   string
}

// String is the one line -check-live prints. It never has the login in it.
func (l LiveResult) String() string {
	s := fmt.Sprintf("reason=%s conn=%d records=%d fresh=%d/%d", l.Reason, l.Conn, l.Records, l.Fresh, l.MinFresh)
	if l.Waiting != "" {
		s += " waiting=" + l.Waiting
	}
	if l.detail != "" {
		s += " " + l.detail
	}
	return s
}

// CheckLive judges one connection of the latest run in Dir against the live
// rules L1, L2, L4, L5 and L6 (L3, the window title, is outside the data). It
// only reads, so it can run beside a recorder that is still writing, and it
// has no deadlines: what has not happened yet is reason=pending, and the caller
// decides when pending has lasted too long, and what that means.
//
// Identity comes first, so wrong_account and fallback_server hold whatever the
// ticks look like. Then only a connection that reached the trade server is
// judged on its ticks, and a definite stale_ticks needs no more data.
func CheckLive(c LiveCheck) LiveResult {
	res := LiveResult{Conn: c.Conn, MinFresh: c.MinFresh}
	verdict := func(reason string, rc int, detail string) LiveResult {
		res.Reason, res.RC, res.detail = reason, rc, detail
		return res
	}
	pending := func(waiting string) LiveResult {
		res.Waiting = waiting
		return verdict("pending", 64, "")
	}
	switch {
	case c.ExpectLogin <= 0:
		return verdict("env_missing", 10, "missing=-expect-login")
	case c.ExpectServer == "":
		return verdict("expect_server_missing", 12, "missing=-expect-server")
	case c.Conn == 0:
		return verdict("unclassified", 1, "bad=-conn")
	case c.MinFresh < 1:
		return verdict("unclassified", 1, "bad=-min-fresh")
	}
	now := time.Now
	if c.Now != nil {
		now = c.Now
	}

	ev, err := readLiveEvents(c)
	if err != nil {
		return verdict("unclassified", 1, fmt.Sprintf("error=%q", err.Error()))
	}
	pr, err := readLivePrices(c, ev)
	if err != nil {
		return verdict("unclassified", 1, fmt.Sprintf("error=%q", err.Error()))
	}
	res.Records, res.Fresh = pr.records, pr.fresh

	// L1. Login 0 is a terminal that has not logged in yet.
	switch {
	case ev.account == nil || ev.account.Login == 0:
		return pending("account")
	case ev.account.Login != c.ExpectLogin:
		return verdict("wrong_account", 25, fmt.Sprintf("server=%q", ev.account.Server))
	case ev.account.Server != c.ExpectServer:
		if now().Sub(ev.fallbackSince) < liveFallbackHold {
			return pending("account")
		}
		return verdict("fallback_server", 22, fmt.Sprintf("server=%q", ev.account.Server))
	}
	// L2.
	if ev.connected == nil || !*ev.connected {
		return pending("connected")
	}
	if pr.belowRestart {
		return verdict("stale_ticks", 29, fmt.Sprintf("first_fresh_msc=%d last_before_restart_msc=%d", pr.firstMsc, pr.floorMsc))
	}
	// L5, on what is here so far: a bad pair stays bad.
	if pr.offPace != 0 {
		return verdict("stale_ticks", 29, fmt.Sprintf("pace_off_ms=%d", pr.offPace))
	}
	// L4.
	if pr.fresh < c.MinFresh {
		return pending("ticks")
	}
	// L6. Ping is in seconds, the tick in milliseconds, on the same clock.
	if pr.last.ServerTime == 0 {
		return pending("server_time")
	}
	age := pr.last.ServerTime*1000 - pr.last.ProviderTimeMsc
	if abs64(age) > liveMaxAgeMsc {
		return verdict("stale_ticks", 29, fmt.Sprintf("last_tick_age_ms=%d", age))
	}
	return verdict("ok", 0, fmt.Sprintf("last_tick_age_ms=%d server=%q company=%q", age, ev.account.Server, ev.account.Company))
}

// liveEvent is what the check needs from a line of events.jsonl.
type liveEvent struct {
	Kind      string    `json:"kind"`
	RunID     string    `json:"run_id"`
	Conn      uint64    `json:"conn"`
	At        time.Time `json:"at"`
	Login     int64     `json:"login"`
	Server    string    `json:"server"`
	Company   string    `json:"company"`
	Connected *bool     `json:"trade_server_connected"`
}

// liveEvents is the latest run's view of one connection.
type liveEvents struct {
	run           string
	account       *liveEvent // the latest account event
	identitySince time.Time  // the account has been the expected one since this event
	fallbackSince time.Time  // the expected login has been on another server since this event
	connected     *bool      // the latest terminal_info
}

func readLiveEvents(c LiveCheck) (liveEvents, error) {
	var ev liveEvents
	err := eachLiveLine(filepath.Join(c.Dir, "events.jsonl"), func(line []byte) error {
		var e liveEvent
		if err := json.Unmarshal(line, &e); err != nil {
			return err
		}
		if e.Kind == "run_start" {
			ev = liveEvents{run: e.RunID}
			return nil
		}
		if e.RunID != ev.run || e.Conn != c.Conn {
			return nil
		}
		switch e.Kind {
		case "account":
			ev.account = &e
			switch {
			case e.Login != c.ExpectLogin:
				ev.identitySince, ev.fallbackSince = time.Time{}, time.Time{}
			case e.Server != c.ExpectServer:
				ev.identitySince = time.Time{}
				if ev.fallbackSince.IsZero() {
					ev.fallbackSince = e.At
				}
			default:
				ev.fallbackSince = time.Time{}
				if ev.identitySince.IsZero() {
					ev.identitySince = e.At
				}
			}
		case "terminal_info":
			ev.connected = e.Connected
		}
		return nil
	})
	return ev, err
}

// livePrices is what the connection's records add up to.
type livePrices struct {
	records      int
	fresh        int
	last         PriceRecord // the last accepted
	offPace      int64       // the first pair off pace (L5), in ms; 0 if none
	firstMsc     int64       // the first accepted
	floorMsc     int64       // the highest value on earlier connections of this run
	belowRestart bool        // the first accepted is not above floorMsc
}

func readLivePrices(c LiveCheck, ev liveEvents) (livePrices, error) {
	var pr livePrices
	err := eachLiveLine(filepath.Join(c.Dir, "prices.jsonl"), func(line []byte) error {
		var p PriceRecord
		if err := json.Unmarshal(line, &p); err != nil {
			return err
		}
		if p.RunID != ev.run {
			return nil
		}
		// Earlier connections only set the value a restart must beat.
		if p.Conn < c.Conn && p.ProviderTimeMsc > pr.floorMsc {
			pr.floorMsc = p.ProviderTimeMsc
		}
		if p.Conn != c.Conn {
			return nil
		}
		pr.records++
		if pr.records == 1 {
			return nil // the EA sends the cached quote first
		}
		// L4: after the L1 event, naming the expected account. L2: the poll
		// before it found a trade server.
		if ev.identitySince.IsZero() || p.ReceivedAt.Before(ev.identitySince) ||
			p.Login != c.ExpectLogin || p.Server != c.ExpectServer || !p.TradeServerConnected {
			return nil
		}
		if pr.fresh == 0 {
			pr.firstMsc = p.ProviderTimeMsc
			pr.belowRestart = pr.floorMsc != 0 && p.ProviderTimeMsc <= pr.floorMsc
		} else {
			if p.ProviderTimeMsc <= pr.last.ProviderTimeMsc {
				return nil // L4: strictly rising
			}
			// L5, from the second accepted record.
			off := (p.ProviderTimeMsc - pr.last.ProviderTimeMsc) - p.ReceivedAt.Sub(pr.last.ReceivedAt).Milliseconds()
			if pr.offPace == 0 && abs64(off) > livePaceMsc {
				pr.offPace = off
			}
		}
		pr.fresh++
		pr.last = p
		return nil
	})
	return pr, err
}

// eachLiveLine calls f on every finished line of path. A file that does not
// exist yet has no lines, and a last line without its newline is still being
// written. A finished line f cannot read stops the check: skipping it could
// hide the very record the rules are about.
func eachLiveLine(path string, f func(line []byte) error) error {
	file, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer file.Close()
	br := bufio.NewReader(file)
	for n := 1; ; n++ {
		line, err := br.ReadBytes('\n')
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if err := f(line); err != nil {
			return fmt.Errorf("%s line %d: %w", filepath.Base(path), n, err)
		}
	}
}

func abs64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}
