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

func (r *Recorder) setErr(err error) {
	r.mu.Lock()
	r.st.LastError = err.Error()
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
	Seq          uint64 `json:"seq"`
	Feed         string `json:"feed"` // "mt5"
	Company      string `json:"broker_company"`
	Server       string `json:"broker_server"`
	Login        int64  `json:"login"`
	BrokerSymbol string `json:"broker_symbol"`
	Instrument   string `json:"instrument"`
	// TradeServerConnected is TerminalInfo.Connected when this tick arrived
	// (refreshed every 10s). false means the value is a cached quote.
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
	r.event("terminal_connected", "login", h.Login, "server", h.Server, "company", h.Company, "build", h.Build,
		"ea_version", h.EAVersion, "remote", term.RemoteAddr().String())
	r.cfg.Log.Info("terminal connected", "login", h.Login, "server", h.Server, "build", h.Build)
	r.mu.Lock()
	r.st.TerminalConnected, r.st.TerminalLogin, r.st.TerminalServer = true, h.Login, h.Server
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		r.st.TerminalConnected = false
		r.st.DroppedTicks += term.DroppedTicks()
		r.mu.Unlock()
		r.event("terminal_disconnected", "login", h.Login, "error", fmt.Sprint(term.Err()), "dropped_ticks", term.DroppedTicks())
		r.cfg.Log.Warn("terminal disconnected", "err", term.Err())
	}()

	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	sym := r.cfg.BrokerSymbol
	if err := term.SymbolSelect(cctx, sym, true); err != nil {
		cands, _ := term.SymbolsGet(cctx, "*XAU*,*GOLD*", false)
		r.event("quality", "what", "broker_symbol_unavailable", "broker_symbol", sym, "error", err.Error(), "candidates", cands)
		r.cfg.Log.Error("broker symbol unavailable; set -broker-symbol", "symbol", sym, "err", err, "candidates", cands)
		r.setErr(fmt.Errorf("broker symbol %q: %v", sym, err))
		// Stay connected so the operator can see it in status; nothing to record.
		select {
		case <-term.Done():
		case <-ctx.Done():
		}
		return nil
	}
	if si, err := term.SymbolInfo(cctx, sym); err == nil {
		r.event("instrument", "broker_symbol", si.Name, "description", si.Description, "digits", si.Digits,
			"currency_base", si.CurrencyBase, "currency_profit", si.CurrencyProfit, "contract_size", si.TradeContractSize,
			"path", si.Path, "login", h.Login, "server", h.Server)
	}
	// Without a trade-server connection (no account) the terminal only holds
	// cached quotes: the first "tick" is the last cached quote, not a live one.
	tradeConn := false
	if ti, err := term.TerminalInfo(cctx); err == nil {
		tradeConn = ti.Connected
		r.event("terminal_info", "trade_server_connected", ti.Connected, "build", ti.Build, "login", h.Login)
		if !ti.Connected {
			r.cfg.Log.Warn("terminal has no trade-server connection: no live prices; any tick is a cached quote (price records carry trade_server_connected=false)")
		}
	}
	r.mu.Lock()
	r.st.TradeServerConnected = tradeConn
	r.mu.Unlock()
	if err := term.SubscribeTicks(cctx, sym); err != nil {
		r.setErr(err)
		r.cfg.Log.Error("subscribe failed", "err", err)
		return nil // drop this connection; the EA reconnects
	}
	r.cfg.Log.Info("subscribed to broker ticks", "symbol", sym)
	summary := time.NewTicker(10 * time.Second)
	defer summary.Stop()
	var n uint64
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-summary.C:
			ictx, icancel := context.WithTimeout(ctx, 10*time.Second)
			if ti, err := term.TerminalInfo(ictx); err == nil && ti.Connected != tradeConn {
				tradeConn = ti.Connected
				r.event("terminal_info", "trade_server_connected", ti.Connected, "build", ti.Build, "login", h.Login)
				r.mu.Lock()
				r.st.TradeServerConnected = tradeConn
				r.mu.Unlock()
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
			rec := PriceRecord{Schema: Schema, ID: id, RunID: r.runID, Seq: seq, Feed: "mt5", Company: h.Company, Server: h.Server,
				Login: h.Login, BrokerSymbol: sym, Instrument: r.cfg.PriceInstrument, Bid: tk.Bid, Ask: tk.Ask, Last: tk.Last,
				TradeServerConnected: tradeConn, Volume: tk.Volume, VolumeReal: tk.VolumeReal, Flags: int(tk.Flags), ProviderTimeMsc: tk.TimeMsc,
				ProviderTimeText:  mt5.ServerTimeMsc(tk.TimeMsc).Format("2006-01-02T15:04:05.000"),
				ProviderTimeBasis: "broker trade-server wall clock (offset to UTC unknown)", ReceivedAt: now}
			if err := r.cfg.Store.Append("prices", rec); err != nil {
				return fmt.Errorf("record: prices: %w", err)
			}
			n++
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
