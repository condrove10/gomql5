// Command goldrec records Myfxbook XAUUSD aggregate positioning and broker
// gold ticks (from a GoBridge EA) side by side, as append-only JSON Lines.
// It does not trade and has no order code path.
//
//	MYFXBOOK_EMAIL=… MYFXBOOK_PASSWORD=… GOBRIDGE_TOKEN=… \
//	  go run ./apps/goldrec -source api -interval 60s -budget 2880 -listen :7788
//
//	# no vendor access: labelled replay of synthetic fixtures + live broker ticks
//	GOBRIDGE_TOKEN=… go run ./apps/goldrec -source replay -interval 15s
//
// See docs/goldrec.md.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/condrove10/gomql5/apps/goldrec/myfxbook"
	"github.com/condrove10/gomql5/apps/goldrec/record"
	"github.com/condrove10/gomql5/mt5"
)

func main() {
	out := flag.String("out", "goldrec-data", "data directory")
	source := flag.String("source", "api", "positioning source: api | replay | none")
	replay := flag.String("replay", "apps/goldrec/myfxbook/testdata/synthetic-outlook-ok.json,apps/goldrec/myfxbook/testdata/synthetic-outlook-changed.json",
		"comma-separated response files for -source replay (synthetic fixtures by default)")
	interval := flag.Duration("interval", 60*time.Second, "positioning poll interval")
	budget := flag.Int("budget", 100, "vendor requests allowed per rolling 24h (100 free / 2880 paid per the docs; verify)")
	ledger := flag.String("ledger", "", "request ledger file (default <out>/ledger.log)")
	entitlement := flag.String("entitlement", "unknown", "declared entitlement written on records (unknown|free|paid)")
	providerSym := flag.String("provider-symbol", "XAUUSD", "symbol name in the Myfxbook response")
	listen := flag.String("listen", ":7788", "address the GoBridge EA connects to (empty: no prices)")
	brokerSym := flag.String("broker-symbol", "XAUUSD", "broker symbol for gold (e.g. GOLD, XAUUSD.r)")
	once := flag.Bool("once", false, "one positioning round, then exit (probe)")
	duration := flag.Duration("duration", 0, "stop after this long (0 = until SIGINT/SIGTERM)")
	apiBase := flag.String("api-base", myfxbook.DefaultBaseURL, "vendor API root")
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	fail := func(msg string, args ...any) { log.Error(msg, args...); os.Exit(1) }

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *duration > 0 {
		var c context.CancelFunc
		ctx, c = context.WithTimeout(ctx, *duration)
		defer c()
	}

	st, err := record.Open(*out)
	if err != nil {
		fail("open store", "err", err)
	}
	defer st.Close()

	cfg := record.Config{Store: st, Log: log, Interval: *interval, Entitlement: *entitlement,
		ProviderSymbol: *providerSym, BrokerSymbol: *brokerSym, SourceMode: *source}

	switch *source {
	case "api":
		lp := *ledger
		if lp == "" {
			lp = filepath.Join(*out, "ledger.log")
		}
		l, err := myfxbook.OpenLedger(lp, *budget)
		if err != nil {
			fail("open ledger", "err", err)
		}
		defer l.Close()
		perDay := int(24 * time.Hour / *interval)
		used, left := l.Used()
		log.Info("request budget", "budget_24h", *budget, "used_24h", used, "remaining", left,
			"interval", interval.String(), "polls_per_24h_at_interval", perDay)
		if *budget > 0 && perDay > *budget {
			log.Warn("interval needs more requests than the budget allows; polls will be refused (status budget_exhausted) once it is spent",
				"needed", perDay, "budget", *budget)
		}
		cfg.Source = &myfxbook.Client{BaseURL: *apiBase, HTTP: &http.Client{Timeout: 30 * time.Second},
			Email: os.Getenv("MYFXBOOK_EMAIL"), Password: os.Getenv("MYFXBOOK_PASSWORD"), Ledger: l}
		if os.Getenv("MYFXBOOK_EMAIL") == "" {
			log.Warn("MYFXBOOK_EMAIL/MYFXBOOK_PASSWORD not set: attempts will be recorded as no_credentials")
		}
	case "replay":
		files := strings.Split(*replay, ",")
		for _, f := range files {
			if _, err := os.Stat(f); err != nil {
				fail("replay file", "err", err)
			}
		}
		log.Warn("REPLAY MODE: positioning records come from files, not from Myfxbook", "files", files)
		cfg.Source = &record.Replay{Files: files}
	case "none":
		cfg.SourceMode = ""
	default:
		fail("unknown -source", "source", *source)
	}

	rec, err := record.New(mustServer(cfg, *listen, *once, log, fail))
	if err != nil {
		fail("config", "err", err)
	}
	log.Info("goldrec started", "run_id", rec.RunID(), "out", st.Dir(), "source", *source, "adapter", record.AdapterVersion)
	if *once {
		if cfg.Source == nil {
			fail("-once needs a positioning source")
		}
		if err := rec.PollOnce(ctx); err != nil {
			fail("poll", "err", err)
		}
		s := rec.Snapshot()
		fmt.Printf("probe: attempts=%v observations=%d quarantined=%d budget_used=%d\n", s.AttemptsByStatus, s.Observations, s.Quarantined, s.BudgetUsed24h)
		return
	}
	if err := rec.Run(ctx); err != nil {
		fail("recorder stopped", "err", err)
	}
	log.Info("goldrec stopped", "status", fmt.Sprintf("%+v", rec.Snapshot()))
}

func mustServer(cfg record.Config, listen string, once bool, log *slog.Logger, fail func(string, ...any)) record.Config {
	if listen == "" || once {
		return cfg
	}
	srv, err := mt5.Listen(listen, mt5.Config{Token: os.Getenv("GOBRIDGE_TOKEN"), Logger: log})
	if err != nil {
		fail("listen for EA", "err", err)
	}
	log.Info("waiting for GoBridge EA", "addr", srv.Addr().String())
	cfg.Server = srv
	return cfg
}
