// Package record runs the gold positioning recorder: it polls a positioning
// source (the Myfxbook API, or a labelled replay), listens for broker gold
// ticks from a GoBridge EA, and appends both, separately, to a Store.
package record

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/condrove10/gomql5/apps/goldrec/myfxbook"
	"github.com/condrove10/gomql5/mt5"
)

// Schema is written on every record. Bump it when a field changes meaning.
const Schema = "goldrec/1"

// AdapterVersion identifies this code in every record.
const AdapterVersion = "goldrec-0.1.0"

// Source yields one vendor round (zero or more attempts and maybe a response).
// *myfxbook.Client satisfies it; so does Replay.
type Source interface {
	Fetch(ctx context.Context) ([]myfxbook.Attempt, *myfxbook.Response)
}

// Config for a Recorder.
type Config struct {
	Store *Store
	Log   *slog.Logger

	// Positioning.
	Source         Source // nil disables positioning collection
	SourceMode     string // "api" | "replay"; written on every record
	Entitlement    string // free text, e.g. "unknown", "free", "paid"; never inferred
	ProviderSymbol string // default "XAUUSD"
	Interval       time.Duration

	// Prices. Nil Server disables price collection.
	Server       *mt5.Server
	BrokerSymbol string // default "XAUUSD"; "GOLD", "XAUUSD.r" etc. map here
	Instrument   string // canonical instrument of the positioning records, default "XAUUSD"
	// PriceInstrument is the canonical instrument of the price records.
	// Default: "XAUUSD" when BrokerSymbol looks like gold (XAU…, GOLD…),
	// otherwise BrokerSymbol itself, so a non-gold feed is never labelled gold.
	PriceInstrument string

	FlushEvery  time.Duration // price stream flush period, default 1s
	StatusEvery time.Duration // default 5s

	// HealthEvery is how often a connected terminal is checked
	// (TerminalInfo, AccountInfo, Ping, tick silence). Default 5s.
	HealthEvery time.Duration
	// ResyncQuiet: while the terminal is connected to a trade server and no
	// tick has arrived for this long, re-select and re-subscribe the symbol
	// (and record why). Default 10s.
	ResyncQuiet time.Duration
	// SelectRetry: while the terminal refuses the broker symbol, how often to
	// ask again, for as long as the connection lasts. Default 5s.
	SelectRetry time.Duration
}

// Recorder is safe to run once.
type Recorder struct {
	cfg   Config
	runID string

	mu       sync.Mutex
	seq      map[string]uint64
	prev     *myfxbook.Values
	st       Status
	lastTick time.Time
	term     termState
}

// termState is what is known about the current EA connection: the hello's
// account until a health poll answers, then the latest poll's. The hello is
// sent at connect, often before the login finishes, so it can say login=0 or
// name a server the terminal then leaves.
type termState struct {
	conn       uint64 // per-run connection counter, from 1
	login      int64
	server     string
	company    string
	connected  bool  // TerminalInfo.Connected
	serverTime int64 // Ping: the trade server's clock, seconds
}

// Status is the health snapshot in status.json.
type Status struct {
	Schema    string    `json:"schema"`
	RunID     string    `json:"run_id"`
	StartedAt time.Time `json:"started_at"`
	UpdatedAt time.Time `json:"updated_at"`

	SourceMode         string            `json:"source_mode"`
	IntervalSeconds    float64           `json:"interval_seconds"`
	Attempts           uint64            `json:"attempts"`
	AttemptsByStatus   map[string]uint64 `json:"attempts_by_status"`
	LastAttemptAt      time.Time         `json:"last_attempt_at,omitempty"`
	LastAttemptStatus  string            `json:"last_attempt_status,omitempty"`
	Observations       uint64            `json:"observations"`
	Quarantined        uint64            `json:"quarantined"`
	LastObservationAt  time.Time         `json:"last_observation_at,omitempty"`
	LastValueChangeAt  time.Time         `json:"last_value_change_at,omitempty"`
	ProviderTimeKnown  bool              `json:"provider_time_known"` // always false for the API: it supplies none
	BudgetUsed24h      int               `json:"budget_used_24h"`
	BudgetRemaining24h int               `json:"budget_remaining_24h"`

	TerminalConnected    bool      `json:"terminal_connected"`
	TradeServerConnected bool      `json:"trade_server_connected"`
	TerminalLogin        int64     `json:"terminal_login,omitempty"`
	TerminalServer       string    `json:"terminal_server,omitempty"`
	BrokerSymbol         string    `json:"broker_symbol,omitempty"`
	Ticks                uint64    `json:"ticks"`
	LastTickReceived     time.Time `json:"last_tick_received_at,omitempty"`
	DroppedTicks         uint64    `json:"dropped_ticks"`
	LastError            string    `json:"last_error,omitempty"`
}

// New validates cfg.
func New(cfg Config) (*Recorder, error) {
	if cfg.Store == nil {
		return nil, fmt.Errorf("record: Store required")
	}
	if cfg.Source == nil && cfg.Server == nil {
		return nil, fmt.Errorf("record: nothing to record (no Source and no Server)")
	}
	if cfg.Log == nil {
		cfg.Log = slog.Default()
	}
	def := func(s *string, v string) {
		if *s == "" {
			*s = v
		}
	}
	def(&cfg.ProviderSymbol, "XAUUSD")
	def(&cfg.BrokerSymbol, "XAUUSD")
	def(&cfg.Instrument, "XAUUSD")
	def(&cfg.PriceInstrument, defaultPriceInstrument(cfg.BrokerSymbol))
	def(&cfg.Entitlement, "unknown")
	if cfg.Source != nil {
		def(&cfg.SourceMode, "api")
		if cfg.Interval <= 0 {
			return nil, fmt.Errorf("record: Interval required with a Source")
		}
	}
	if cfg.FlushEvery <= 0 {
		cfg.FlushEvery = time.Second
	}
	if cfg.StatusEvery <= 0 {
		cfg.StatusEvery = 5 * time.Second
	}
	if cfg.HealthEvery <= 0 {
		cfg.HealthEvery = 5 * time.Second
	}
	if cfg.ResyncQuiet <= 0 {
		cfg.ResyncQuiet = 10 * time.Second
	}
	if cfg.SelectRetry <= 0 {
		cfg.SelectRetry = 5 * time.Second
	}
	var b [8]byte
	rand.Read(b[:])
	r := &Recorder{cfg: cfg, runID: time.Now().UTC().Format("20060102T150405Z") + "-" + hex.EncodeToString(b[:4]), seq: map[string]uint64{}}
	r.st = Status{Schema: Schema, RunID: r.runID, StartedAt: time.Now().UTC(), SourceMode: cfg.SourceMode,
		IntervalSeconds: cfg.Interval.Seconds(), AttemptsByStatus: map[string]uint64{}, BrokerSymbol: cfg.BrokerSymbol}
	return r, nil
}

// RunID identifies this process run in every record.
func (r *Recorder) RunID() string { return r.runID }

// Snapshot returns a copy of the current status.
func (r *Recorder) Snapshot() Status {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.st
	s.AttemptsByStatus = map[string]uint64{}
	for k, v := range r.st.AttemptsByStatus {
		s.AttemptsByStatus[k] = v
	}
	return s
}

func (r *Recorder) next(stream string) (string, uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.seq[stream]++
	n := r.seq[stream]
	return fmt.Sprintf("%s-%s-%d", r.runID, stream[:1], n), n
}

func (r *Recorder) event(kind string, kv ...any) {
	id, seq := r.next("events")
	rec := map[string]any{"schema": Schema, "id": id, "run_id": r.runID, "seq": seq, "at": time.Now().UTC(), "kind": kind}
	for i := 0; i+1 < len(kv); i += 2 {
		rec[fmt.Sprint(kv[i])] = kv[i+1]
	}
	if err := r.cfg.Store.AppendSync("events", rec); err != nil {
		r.cfg.Log.Error("events write failed", "err", err)
	}
}

// connEvent is event for anything that belongs to the current EA connection.
// priceLoop serves one connection at a time, so the current one is unambiguous.
func (r *Recorder) connEvent(kind string, kv ...any) {
	r.event(kind, append(kv, "conn", r.termNow().conn)...)
}

func (r *Recorder) termNow() termState {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.term
}

func (r *Recorder) updateTerm(f func(*termState)) {
	r.mu.Lock()
	defer r.mu.Unlock()
	f(&r.term)
	r.st.TerminalLogin, r.st.TerminalServer, r.st.TradeServerConnected = r.term.login, r.term.server, r.term.connected
}

func (r *Recorder) setErr(err error) {
	r.mu.Lock()
	r.st.LastError = err.Error()
	r.mu.Unlock()
}

func (r *Recorder) clearErr() {
	r.mu.Lock()
	r.st.LastError = ""
	r.mu.Unlock()
}

// Run blocks until ctx ends. A store write failure stops the recorder with an
// error rather than silently dropping data.
func (r *Recorder) Run(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	r.event("run_start", "adapter_version", AdapterVersion, "source_mode", r.cfg.SourceMode,
		"interval_seconds", r.cfg.Interval.Seconds(), "provider_symbol", r.cfg.ProviderSymbol,
		"broker_symbol", r.cfg.BrokerSymbol, "prices_enabled", r.cfg.Server != nil, "positioning_enabled", r.cfg.Source != nil)

	errc := make(chan error, 3)
	var wg sync.WaitGroup
	start := func(f func(context.Context) error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := f(ctx); err != nil && ctx.Err() == nil {
				errc <- err
				cancel()
			}
		}()
	}
	if r.cfg.Source != nil {
		start(r.positioningLoop)
	}
	if r.cfg.Server != nil {
		start(r.priceLoop)
	}
	start(r.housekeeping)
	wg.Wait()
	var err error
	select {
	case err = <-errc:
	default:
	}
	r.event("run_stop", "error", fmt.Sprint(err))
	r.writeStatus()
	if ferr := r.cfg.Store.Flush(); err == nil {
		err = ferr
	}
	return err
}

func (r *Recorder) housekeeping(ctx context.Context) error {
	ft := time.NewTicker(r.cfg.FlushEvery)
	st := time.NewTicker(r.cfg.StatusEvery)
	defer ft.Stop()
	defer st.Stop()
	r.writeStatus()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ft.C:
			if err := r.cfg.Store.Flush(); err != nil {
				return fmt.Errorf("record: flush: %w", err)
			}
		case <-st.C:
			r.writeStatus()
		}
	}
}

func (r *Recorder) writeStatus() {
	s := r.Snapshot()
	s.UpdatedAt = time.Now().UTC()
	if err := r.cfg.Store.WriteStatus(s); err != nil {
		r.cfg.Log.Error("status write failed", "err", err)
	}
}

// ---- positioning ----------------------------------------------------------

func (r *Recorder) positioningLoop(ctx context.Context) error {
	t := time.NewTicker(r.cfg.Interval)
	defer t.Stop()
	for {
		if err := r.PollOnce(ctx); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

// AttemptRecord is a line of attempts.jsonl.
type AttemptRecord struct {
	Schema     string `json:"schema"`
	ID         string `json:"id"`
	RunID      string `json:"run_id"`
	Seq        uint64 `json:"seq"`
	SourceMode string `json:"source_mode"`
	Adapter    string `json:"adapter_version"`
	myfxbook.Attempt
	RawRef string `json:"raw_ref,omitempty"`
}

// SentimentRecord is a line of sentiment.jsonl.
type SentimentRecord struct {
	Schema     string `json:"schema"`
	ID         string `json:"id"`
	RunID      string `json:"run_id"`
	Seq        uint64 `json:"seq"`
	AttemptID  string `json:"attempt_id"`
	Provider   string `json:"provider"`
	SourceMode string `json:"source_mode"` // api | replay
	Adapter    string `json:"adapter_version"`
	// Entitlement and delay are declared by the operator, not observed.
	Entitlement   string `json:"entitlement"`
	DeclaredDelay string `json:"declared_delay"`
	Instrument    string `json:"instrument"`
	myfxbook.Normalized
	// CollectedAt is when the response finished arriving (UTC). The API
	// supplies no observation time, so ProviderTime is always null.
	CollectedAt      time.Time  `json:"collected_at"`
	RequestStart     time.Time  `json:"request_start"`
	ProviderTime     *time.Time `json:"provider_time"`
	ProviderTimeNote string     `json:"provider_time_note"`
	// SameAsPrevious compares supplied values with this run's previous
	// observation. Unchanged values are recorded, never deduplicated.
	SameAsPrevious *bool  `json:"same_as_previous"`
	DuplicateMatch bool   `json:"duplicate_symbol_match,omitempty"`
	RawRef         string `json:"raw_ref,omitempty"`
}

// PollOnce runs one vendor round and records it. It returns an error only for
// store failures.
func (r *Recorder) PollOnce(ctx context.Context) error {
	atts, resp := r.cfg.Source.Fetch(ctx)
	var lastID, lastRaw string
	var last myfxbook.Attempt
	for _, a := range atts {
		id, seq := r.next("attempts")
		rec := AttemptRecord{Schema: Schema, ID: id, RunID: r.runID, Seq: seq, SourceMode: r.cfg.SourceMode, Adapter: AdapterVersion, Attempt: a}
		if a.Method != "login" && len(a.Body) > 0 && a.BodySHA256 != "" {
			ref, err := r.cfg.Store.PutRaw(a.BodySHA256, a.Body)
			if err != nil {
				return fmt.Errorf("record: raw archive: %w", err)
			}
			rec.RawRef = ref
		}
		if err := r.cfg.Store.AppendSync("attempts", rec); err != nil {
			return fmt.Errorf("record: attempts: %w", err)
		}
		r.mu.Lock()
		r.st.Attempts++
		r.st.AttemptsByStatus[a.Status]++
		r.st.LastAttemptAt, r.st.LastAttemptStatus = a.End, a.Status
		r.st.BudgetUsed24h, r.st.BudgetRemaining24h = a.BudgetUsed, a.BudgetLeft
		r.mu.Unlock()
		if a.Status != myfxbook.StatusOK {
			r.cfg.Log.Warn("positioning attempt failed", "method", a.Method, "status", a.Status, "http", a.HTTPStatus, "message", a.Message,
				"budget_left", a.BudgetLeft)
		}
		lastID, lastRaw, last = id, rec.RawRef, a
	}
	if resp == nil || last.Status != myfxbook.StatusOK {
		return nil
	}
	matches := resp.Find(r.cfg.ProviderSymbol)
	if len(matches) == 0 {
		r.event("quality", "what", "symbol_absent", "provider_symbol", r.cfg.ProviderSymbol, "attempt_id", lastID,
			"symbols_in_response", len(resp.Symbols))
		r.cfg.Log.Warn("positioning response has no symbol", "symbol", r.cfg.ProviderSymbol, "symbols", len(resp.Symbols))
		return nil
	}
	if len(resp.Extra) > 0 {
		keys := make([]string, 0, len(resp.Extra))
		for k := range resp.Extra {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		r.event("quality", "what", "unknown_top_level_fields", "fields", keys, "attempt_id", lastID)
	}
	for _, m := range matches {
		n := myfxbook.Normalize(m)
		id, seq := r.next("sentiment")
		rec := SentimentRecord{Schema: Schema, ID: id, RunID: r.runID, Seq: seq, AttemptID: lastID, Provider: "myfxbook",
			SourceMode: r.cfg.SourceMode, Adapter: AdapterVersion, Entitlement: r.cfg.Entitlement, DeclaredDelay: "unknown",
			Instrument: r.cfg.Instrument, Normalized: n, CollectedAt: last.End, RequestStart: last.Start,
			ProviderTimeNote: "not supplied by source", DuplicateMatch: len(matches) > 1, RawRef: lastRaw}
		r.mu.Lock()
		if r.prev != nil && !n.Quarantined {
			same := reflect.DeepEqual(*r.prev, n.Supplied)
			rec.SameAsPrevious = &same
		}
		changed := rec.SameAsPrevious == nil || !*rec.SameAsPrevious
		if !n.Quarantined {
			v := n.Supplied
			r.prev = &v
		}
		r.mu.Unlock()
		stream := "sentiment"
		if n.Quarantined {
			stream = "quarantine"
		}
		if err := r.cfg.Store.AppendSync(stream, rec); err != nil {
			return fmt.Errorf("record: %s: %w", stream, err)
		}
		r.mu.Lock()
		if n.Quarantined {
			r.st.Quarantined++
		} else {
			r.st.Observations++
			r.st.LastObservationAt = rec.CollectedAt
			if changed {
				r.st.LastValueChangeAt = rec.CollectedAt
			}
		}
		r.mu.Unlock()
		r.cfg.Log.Info("positioning", "mode", r.cfg.SourceMode, "symbol", n.ProviderSymbol,
			"long_pct", deref(n.Supplied.LongPercentage), "short_pct", deref(n.Supplied.ShortPercentage),
			"long_lots", deref(n.Supplied.LongVolume), "short_lots", deref(n.Supplied.ShortVolume),
			"long_pos", deref(n.Supplied.LongPositions), "short_pos", deref(n.Supplied.ShortPositions),
			"quality", n.Quality, "quarantined", n.Quarantined, "id", id)
	}
	return nil
}

func deref(p *string) string {
	if p == nil {
		return "n/a"
	}
	return *p
}

// ---- prices ---------------------------------------------------------------

// PriceRecord is a line of prices.jsonl.
type PriceRecord struct {
	Schema       string `json:"schema"`
	ID           string `json:"id"`
	RunID        string `json:"run_id"`
	Conn         uint64 `json:"conn"` // per-run EA connection counter, from 1
	Seq          uint64 `json:"seq"`
	Feed         string `json:"feed"` // "mt5"
	Company      string `json:"broker_company"`
	Server       string `json:"broker_server"`
	Login        int64  `json:"login"`
	BrokerSymbol string `json:"broker_symbol"`
	Instrument   string `json:"instrument"`
	// TradeServerConnected is TerminalInfo.Connected in the latest health
	// poll. false means the value is a cached quote.
	TradeServerConnected bool    `json:"trade_server_connected"`
	Bid                  float64 `json:"bid"`
	Ask                  float64 `json:"ask"`
	Last                 float64 `json:"last"`
	Volume               uint64  `json:"volume"`
	VolumeReal           float64 `json:"volume_real"`
	Flags                int     `json:"flags"`
	// ProviderTimeMsc is MqlTick.time_msc verbatim: the broker trade server's
	// wall clock, encoded as if UTC. Its offset to UTC is not known here.
	ProviderTimeMsc   int64     `json:"provider_time_msc"`
	ProviderTimeText  string    `json:"provider_time_broker_wallclock"`
	ProviderTimeBasis string    `json:"provider_time_basis"`
	ReceivedAt        time.Time `json:"received_at"`
	// ServerTime is Ping in the latest health poll: seconds on the same clock
	// as ProviderTimeMsc, 0 if no poll has answered.
	ServerTime int64 `json:"server_time"`
}

func (r *Recorder) priceLoop(ctx context.Context) error {
	for {
		term, err := r.cfg.Server.Accept(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("record: accept: %w", err)
		}
		if err := r.serveTerminal(ctx, term); err != nil {
			term.Close()
			return err
		}
		term.Close()
	}
}

// serveTerminal records ticks until the terminal disconnects (nil) or a
// store write fails (error).
func (r *Recorder) serveTerminal(ctx context.Context, term *mt5.Terminal) error {
	h := term.Hello()
	r.updateTerm(func(t *termState) {
		*t = termState{conn: t.conn + 1, login: h.Login, server: h.Server, company: h.Company}
	})
	r.connEvent("terminal_connected", "login", h.Login, "server", h.Server, "company", h.Company, "build", h.Build,
		"ea_version", h.EAVersion, "remote", term.RemoteAddr().String())
	r.cfg.Log.Info("terminal connected", "login", h.Login, "server", h.Server, "build", h.Build)
	r.mu.Lock()
	r.st.TerminalConnected = true
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		r.st.TerminalConnected = false
		r.st.DroppedTicks += term.DroppedTicks()
		r.mu.Unlock()
		r.connEvent("terminal_disconnected", "login", r.termNow().login, "error", fmt.Sprint(term.Err()), "dropped_ticks", term.DroppedTicks())
		r.cfg.Log.Warn("terminal disconnected", "err", term.Err())
	}()

	// First poll before the symbol, so nothing below is written with the
	// hello's account; then it keeps running whatever happens to the symbol.
	var seen pollSeen
	r.pollHealth(ctx, term, &seen)
	tradeConn := r.termNow().connected
	hctx, hstop := context.WithCancel(ctx)
	var hwg sync.WaitGroup
	hwg.Add(1)
	go func() {
		defer hwg.Done()
		r.healthLoop(hctx, term, &seen)
	}()
	defer func() { // runs before terminal_disconnected is written
		hstop()
		hwg.Wait()
	}()

	sym := r.cfg.BrokerSymbol
	if !r.selectSymbol(ctx, term, sym) {
		return nil
	}
	ictx, icancel := context.WithTimeout(ctx, symbolCallTimeout)
	si, err := term.SymbolInfo(ictx, sym)
	icancel()
	if err == nil {
		ts := r.termNow()
		r.connEvent("instrument", "broker_symbol", si.Name, "description", si.Description, "digits", si.Digits,
			"currency_base", si.CurrencyBase, "currency_profit", si.CurrencyProfit, "contract_size", si.TradeContractSize,
			"path", si.Path, "login", ts.login, "server", ts.server)
	}
	sctx, scancel := context.WithTimeout(ctx, symbolCallTimeout)
	err = term.SubscribeTicks(sctx, sym)
	scancel()
	if err != nil {
		r.setErr(err)
		r.cfg.Log.Error("subscribe failed", "err", err)
		return nil // drop this connection; the EA reconnects
	}
	r.cfg.Log.Info("subscribed to broker ticks", "symbol", sym)
	summary := time.NewTicker(r.cfg.HealthEvery)
	defer summary.Stop()
	var n uint64
	// quietSince: last tick or last (re)subscription on this connection.
	quietSince := time.Now()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-summary.C:
			ictx, icancel := context.WithTimeout(ctx, 10*time.Second)
			if up := r.termNow().connected; up != tradeConn {
				tradeConn = up
				if tradeConn {
					// The account sync after a login can rebuild Market Watch
					// and drop a symbol selected before it; the EA then polls
					// SymbolInfoTick in vain, silently (user's FTMO run:
					// subscribed 23:43:39, synchronized 23:43:44, 0 ticks).
					r.resync(ictx, term, sym, "trade_server_connected")
					quietSince = time.Now()
				}
			} else if tradeConn && time.Since(quietSince) >= r.cfg.ResyncQuiet {
				r.resync(ictx, term, sym, "no_ticks")
				quietSince = time.Now()
			}
			icancel()
			r.mu.Lock()
			lt := r.lastTick
			r.mu.Unlock()
			r.cfg.Log.Info("prices", "symbol", sym, "ticks_this_connection", n, "last_tick_received", lt.Format(time.RFC3339Nano),
				"dropped", term.DroppedTicks())
		case tk, ok := <-term.Ticks():
			if !ok {
				return nil
			}
			if tk.Symbol != "" && tk.Symbol != sym {
				continue
			}
			now := time.Now().UTC()
			id, seq := r.next("prices")
			ts := r.termNow()
			rec := PriceRecord{Schema: Schema, ID: id, RunID: r.runID, Conn: ts.conn, Seq: seq, Feed: "mt5", Company: ts.company, Server: ts.server,
				Login: ts.login, BrokerSymbol: sym, Instrument: r.cfg.PriceInstrument, Bid: tk.Bid, Ask: tk.Ask, Last: tk.Last,
				TradeServerConnected: ts.connected, ServerTime: ts.serverTime, Volume: tk.Volume, VolumeReal: tk.VolumeReal, Flags: int(tk.Flags), ProviderTimeMsc: tk.TimeMsc,
				ProviderTimeText:  mt5.ServerTimeMsc(tk.TimeMsc).Format("2006-01-02T15:04:05.000"),
				ProviderTimeBasis: "broker trade-server wall clock (offset to UTC unknown)", ReceivedAt: now}
			if err := r.cfg.Store.Append("prices", rec); err != nil {
				return fmt.Errorf("record: prices: %w", err)
			}
			n++
			quietSince = now
			r.mu.Lock()
			r.st.Ticks++
			r.st.LastTickReceived = now
			r.lastTick = now
			r.mu.Unlock()
			if n == 1 {
				r.cfg.Log.Info("first broker tick", "symbol", sym, "bid", tk.Bid, "ask", tk.Ask, "broker_time", rec.ProviderTimeText)
			}
		}
	}
}

// symbolCallTimeout bounds each call around selecting the symbol on its own:
// the retry has no end, so no deadline can be shared between its calls.
const symbolCallTimeout = 10 * time.Second

// selectSymbol selects sym, asking again every SelectRetry, and reports whether
// it did before the connection ended. A refusal says little until the account
// is synchronized, because the sync rebuilds Market Watch and brings the
// broker's symbols in; judging it at a deadline is up to whoever reads the
// events. The event is written when the error or the candidates change, and a
// failed SymbolsGet keeps the previous candidates, so a quiet retry writes
// nothing. The error in status lasts until a select succeeds.
func (r *Recorder) selectSymbol(ctx context.Context, term *mt5.Terminal, sym string) bool {
	t := time.NewTicker(r.cfg.SelectRetry)
	defer t.Stop()
	var cands []string
	var seen string
	for {
		sctx, scancel := context.WithTimeout(ctx, symbolCallTimeout)
		err := term.SymbolSelect(sctx, sym, true)
		scancel()
		if err == nil {
			r.clearErr()
			return true
		}
		// The call failed because the connection went: that is no news about
		// the symbol. Err, because a pending call wakes before Done closes.
		if ctx.Err() != nil || term.Err() != nil {
			return false
		}
		gctx, gcancel := context.WithTimeout(ctx, symbolCallTimeout)
		if c, gerr := term.SymbolsGet(gctx, candidatesPattern(sym), false); gerr == nil {
			cands = c
		}
		gcancel()
		if now := err.Error() + "\x00" + strings.Join(cands, ","); now != seen {
			seen = now
			r.connEvent("quality", "what", "broker_symbol_unavailable", "broker_symbol", sym, "error", err.Error(), "candidates", cands)
			r.cfg.Log.Error("broker symbol unavailable; set -broker-symbol", "symbol", sym, "err", err, "candidates", cands)
			r.setErr(fmt.Errorf("broker symbol %q: %v", sym, err))
		}
		select {
		case <-t.C:
		case <-term.Done():
			return false
		case <-ctx.Done():
			return false
		}
	}
}

// healthCallTimeout bounds each call of a health poll on its own.
const healthCallTimeout = 10 * time.Second

// pollSeen is what one connection's health poll last wrote, so its events
// appear on change. It belongs to the connection: a new connection is a new
// login, and the checks read one connection alone, so it writes them again.
type pollSeen struct {
	account   *accountSeen
	connected *bool
}

// accountSeen holds only what the account event may carry. AccountInfo also
// holds the holder's name and balance, and events.jsonl goes into the bundle.
type accountSeen struct {
	login        int64
	server       string
	company      string
	tradeAllowed bool
}

// healthLoop polls until ctx ends or the terminal disconnects.
func (r *Recorder) healthLoop(ctx context.Context, term *mt5.Terminal, seen *pollSeen) {
	t := time.NewTicker(r.cfg.HealthEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-term.Done():
			return
		case <-t.C:
			r.pollHealth(ctx, term, seen)
		}
	}
}

// pollHealth asks the terminal which account it is on, whether it reaches the
// trade server and what time the server says. A call that fails leaves the
// previous value and writes nothing, so a silent account_info cannot look like
// an account. An event is written before the state it announces, so no record
// names an account ahead of its event.
func (r *Recorder) pollHealth(ctx context.Context, term *mt5.Terminal, seen *pollSeen) {
	warn := func(call string, err error) {
		if ctx.Err() == nil {
			r.cfg.Log.Warn("health poll failed", "call", call, "err", err)
		}
	}
	actx, acancel := context.WithTimeout(ctx, healthCallTimeout)
	a, err := term.AccountInfo(actx)
	acancel()
	if err != nil {
		warn("account_info", err)
	} else {
		now := accountSeen{login: a.Login, server: a.Server, company: a.Company, tradeAllowed: a.TradeAllowed}
		if seen.account == nil || *seen.account != now {
			r.connEvent("account", "login", now.login, "server", now.server, "company", now.company, "trade_allowed", now.tradeAllowed)
			seen.account = &now
		}
		r.updateTerm(func(t *termState) { t.login, t.server, t.company = now.login, now.server, now.company })
	}

	tctx, tcancel := context.WithTimeout(ctx, healthCallTimeout)
	ti, err := term.TerminalInfo(tctx)
	tcancel()
	if err != nil {
		warn("terminal_info", err)
	} else {
		if seen.connected == nil || *seen.connected != ti.Connected {
			r.connEvent("terminal_info", "trade_server_connected", ti.Connected, "build", ti.Build, "login", r.termNow().login)
			// Without a trade-server connection (no account) the terminal only
			// holds cached quotes: the first "tick" is the last cached quote.
			if seen.connected == nil && !ti.Connected {
				r.cfg.Log.Warn("terminal has no trade-server connection: no live prices; any tick is a cached quote (price records carry trade_server_connected=false)")
			}
			seen.connected = &ti.Connected
		}
		r.updateTerm(func(t *termState) { t.connected = ti.Connected })
	}

	pctx, pcancel := context.WithTimeout(ctx, healthCallTimeout)
	sec, err := term.Ping(pctx)
	pcancel()
	if err != nil {
		warn("ping", err)
	} else {
		r.updateTerm(func(t *termState) { t.serverTime = sec })
	}
}

// resync re-selects and re-subscribes the broker symbol and records what the
// terminal says about it, so a silent tick stream can be told apart:
// select error / not selected (symbol missing or renamed), a quote with an
// old time (market closed), or a fresh quote (ticks should now flow).
func (r *Recorder) resync(ctx context.Context, term *mt5.Terminal, sym, reason string) {
	ts := r.termNow()
	kv := []any{"reason", reason, "broker_symbol", sym, "login", ts.login, "conn", ts.conn}
	if err := term.SymbolSelect(ctx, sym, true); err != nil {
		kv = append(kv, "select_error", err.Error())
		cands, _ := term.SymbolsGet(ctx, candidatesPattern(sym), false)
		kv = append(kv, "candidates", cands)
	}
	if si, err := term.SymbolInfo(ctx, sym); err == nil {
		kv = append(kv, "selected", si.Select, "visible", si.Visible, "path", si.Path, "description", si.Description)
	} else {
		kv = append(kv, "symbol_info_error", err.Error())
	}
	if tk, err := term.SymbolInfoTick(ctx, sym); err == nil {
		kv = append(kv, "quote_bid", tk.Bid, "quote_ask", tk.Ask, "quote_time_msc", tk.TimeMsc,
			"quote_broker_wallclock", mt5.ServerTimeMsc(tk.TimeMsc).Format("2006-01-02T15:04:05.000"))
	} else {
		kv = append(kv, "quote_error", err.Error())
	}
	// Broker clock in seconds, so an old quote_time_msc can be read against it.
	pctx, pcancel := context.WithTimeout(ctx, healthCallTimeout)
	if sec, err := term.Ping(pctx); err == nil {
		kv = append(kv, "server_time", sec)
	} else {
		kv = append(kv, "ping_error", err.Error())
	}
	pcancel()
	if err := term.SubscribeTicks(ctx, sym); err != nil {
		kv = append(kv, "subscribe_error", err.Error())
	}
	r.event("symbol_resync", kv...)
	r.cfg.Log.Info("re-selected and re-subscribed broker symbol", kv...)
}

// ---- replay -----------------------------------------------------------------

// Replay serves response bodies from files, in order, cycling. It exists to
// exercise the pipeline without vendor access; its records say source_mode
// "replay" and must never be presented as live observations.
type Replay struct {
	Files []string
	mu    sync.Mutex
	i     int
}

// Fetch implements Source.
func (p *Replay) Fetch(ctx context.Context) ([]myfxbook.Attempt, *myfxbook.Response) {
	p.mu.Lock()
	f := p.Files[p.i%len(p.Files)]
	p.i++
	p.mu.Unlock()
	start := time.Now().UTC()
	a := myfxbook.Attempt{Method: "replay:" + filepath.Base(f), Start: start, BudgetLeft: -1}
	b, err := os.ReadFile(f)
	a.End = time.Now().UTC()
	if err != nil {
		a.Status, a.Message = myfxbook.StatusTransport, err.Error()
		return []myfxbook.Attempt{a}, nil
	}
	a.Body, a.BodyBytes, a.BodySHA256 = b, len(b), sha256hex(b)
	resp, err := myfxbook.Parse(b)
	switch {
	case err != nil:
		a.Status, a.Message = myfxbook.StatusParse, err.Error()
		return []myfxbook.Attempt{a}, nil
	case resp.Error:
		a.Status, a.Message = myfxbook.StatusApp, resp.Message
	default:
		a.Status = myfxbook.StatusOK
	}
	return []myfxbook.Attempt{a}, resp
}

func sha256hex(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func defaultPriceInstrument(brokerSymbol string) string {
	u := strings.ToUpper(brokerSymbol)
	if strings.HasPrefix(u, "XAUUSD") || strings.HasPrefix(u, "GOLD") {
		return "XAUUSD"
	}
	return brokerSymbol
}

// candidatesPattern is the SymbolsGet group listing likely broker names for
// sym when it is missing: gold's usual aliases, else anything containing the
// first three letters (BTCUSD → "*BTC*", so "BTCUSD.r" or "BTCUSDm" show up).
func candidatesPattern(sym string) string {
	u := strings.ToUpper(sym)
	if strings.HasPrefix(u, "XAU") || strings.HasPrefix(u, "GOLD") || len(u) < 3 {
		return "*XAU*,*GOLD*"
	}
	return "*" + u[:3] + "*"
}
