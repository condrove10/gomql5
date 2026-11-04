package myfxbook

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ErrBudget means sending another request would exceed the 24 h allowance.
var ErrBudget = errors.New("myfxbook: request budget for the last 24h is used up")

// Ledger counts every request sent to the vendor (login, outlook, logout, and
// failed ones) over a rolling 24 h window and persists them, so a restart
// does not reset the count. A rolling window is the conservative reading:
// whether the vendor uses a fixed or rolling window is unverified.
type Ledger struct {
	Budget int // requests allowed per rolling 24h; <=0 means unlimited
	Window time.Duration

	mu   sync.Mutex
	path string
	f    *os.File
	sent []time.Time // ascending
	now  func() time.Time
}

// OpenLedger loads (or creates) the ledger file at path. An empty path keeps
// the ledger in memory only (tests, replay).
func OpenLedger(path string, budget int) (*Ledger, error) {
	l := &Ledger{Budget: budget, Window: 24 * time.Hour, path: path, now: time.Now}
	if path == "" {
		return l, nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	if b, err := os.Open(path); err == nil {
		sc := bufio.NewScanner(b)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" {
				continue
			}
			t, err := time.Parse(time.RFC3339Nano, strings.Fields(line)[0])
			if err != nil {
				continue // a torn last line after a crash: ignore it, the rest still counts
			}
			l.sent = append(l.sent, t)
		}
		b.Close()
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	l.f = f
	return l, nil
}

func (l *Ledger) prune(now time.Time) {
	cut := now.Add(-l.Window)
	i := 0
	for i < len(l.sent) && !l.sent[i].After(cut) {
		i++
	}
	l.sent = l.sent[i:]
}

// Reserve records a request about to be sent, or returns ErrBudget. The entry
// is written and fsynced before returning, so a crash cannot under-count.
func (l *Ledger) Reserve(kind string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now().UTC()
	l.prune(now)
	if l.Budget > 0 && len(l.sent) >= l.Budget {
		return ErrBudget
	}
	if l.f != nil {
		if _, err := fmt.Fprintf(l.f, "%s %s\n", now.Format(time.RFC3339Nano), kind); err != nil {
			return fmt.Errorf("myfxbook: ledger write: %w", err)
		}
		if err := l.f.Sync(); err != nil {
			return fmt.Errorf("myfxbook: ledger sync: %w", err)
		}
	}
	l.sent = append(l.sent, now)
	return nil
}

// Used returns the requests counted in the current window and the remainder
// (-1 when unlimited).
func (l *Ledger) Used() (used, remaining int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.prune(l.now().UTC())
	if l.Budget <= 0 {
		return len(l.sent), -1
	}
	return len(l.sent), l.Budget - len(l.sent)
}

// Close closes the file.
func (l *Ledger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		return nil
	}
	err := l.f.Close()
	l.f = nil
	return err
}
