package myfxbook

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// FuzzParseNormalize: arbitrary bodies never panic, and every value that
// Normalize reports as supplied is finite decimal text that occurs in the
// body (it is never invented, rounded or zero-filled). A record with a
// missing/null/invalid flag is quarantined.
func FuzzParseNormalize(f *testing.F) {
	for _, n := range []string{"synthetic-outlook-ok.json", "synthetic-outlook-quirks.json", "synthetic-outlook-changed.json",
		"captured-2026-11-04-outlook-invalid-session.json"} {
		b, err := os.ReadFile(filepath.Join("testdata", n))
		if err != nil {
			f.Fatal(err)
		}
		f.Add(b)
	}
	f.Add([]byte(`{"error":false,"symbols":[{"name":"XAUUSD","longVolume":"Infinity","shortVolume":"-0","longPositions":1e300}]}`))
	// Forms strconv.ParseFloat accepts but a JSON decimal does not.
	for _, v := range []string{`"+5"`, `".5"`, `"0x1p3"`, `"1_0"`} {
		f.Add([]byte(`{"error":false,"symbols":[{"name":"XAUUSD","longVolume":` + v + `}]}`))
	}
	f.Fuzz(func(t *testing.T, body []byte) {
		r, err := Parse(body)
		if err != nil {
			return
		}
		for _, s := range r.Symbols {
			n := Normalize(s)
			check := func(field string, v *string) {
				if v == nil {
					return
				}
				x, err := strconv.ParseFloat(*v, 64)
				if err != nil || math.IsNaN(x) || math.IsInf(x, 0) || !json.Valid([]byte(*v)) {
					t.Fatalf("%s: non-finite/non-decimal value %q accepted", field, *v)
				}
				if !strings.Contains(string(body), *v) && !strings.Contains(string(s.Fields[field]), *v) {
					t.Fatalf("%s: value %q not present in the input", field, *v)
				}
			}
			for _, fld := range append(append([]string{}, decimalFields...), countFields...) {
				check(fld, *n.Supplied.slot(fld))
			}
			for _, q := range n.Quality {
				if (strings.HasPrefix(q, "missing:") || strings.HasPrefix(q, "null:") || strings.HasPrefix(q, "invalid:")) && !n.Quarantined {
					t.Fatalf("flag %s without quarantine", q)
				}
			}
			for _, d := range []*float64{n.Derived.LongVolumeShare, n.Derived.LongCountShare} {
				if d != nil && (math.IsNaN(*d) || math.IsInf(*d, 0)) {
					t.Fatalf("derived share %v", *d)
				}
			}
		}
	})
}

// FuzzLedgerFile: a corrupted ledger never panics and never counts more
// entries than it has lines (it may count fewer: unparsable lines are skipped).
func FuzzLedgerFile(f *testing.F) {
	f.Add([]byte("2026-11-04T10:00:00Z outlook\n2026-11-04T10:01:00Z login\n"))
	f.Add([]byte("garbage\n\n   \n2026-11-0"))
	f.Add([]byte{0xff, 0xfe, '\n'})
	f.Fuzz(func(t *testing.T, content []byte) {
		p := filepath.Join(t.TempDir(), "ledger.log")
		os.WriteFile(p, content, 0o644)
		l, err := OpenLedger(p, 10)
		if err != nil {
			return
		}
		defer l.Close()
		l.Window = 1 << 62 // count everything regardless of age
		used, _ := l.Used()
		if lines := strings.Count(string(content), "\n") + 1; used > lines {
			t.Fatalf("counted %d entries from %d lines", used, lines)
		}
	})
}
