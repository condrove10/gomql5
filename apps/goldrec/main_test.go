package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The test binary stands in for goldrec, so the flags and exit codes the e2e
// script relies on are tested as a process.
func TestMain(m *testing.M) {
	if os.Getenv("GOLDREC_TEST_RUN_MAIN") == "1" {
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestCheckLiveFlag(t *testing.T) {
	const events = `{"kind":"run_start","run_id":"r","at":"2026-11-05T12:00:00Z"}
{"kind":"account","run_id":"r","conn":1,"at":"2026-11-05T12:00:00Z","login":%d,"server":"Broker-Live","company":"C"}
{"kind":"terminal_info","run_id":"r","conn":1,"at":"2026-11-05T12:00:00Z","trade_server_connected":true}
`
	const price = `{"run_id":"r","conn":1,"login":777001,"broker_server":"Broker-Live","trade_server_connected":true,` +
		`"provider_time_msc":17622684%02d000,"received_at":"2026-11-05T12:00:%02dZ","server_time":17622684%02d}` + "\n"
	write := func(t *testing.T, login, records int) string {
		t.Helper()
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "events.jsonl"), []byte(fmt.Sprintf(events, login)), 0o644); err != nil {
			t.Fatal(err)
		}
		var p strings.Builder
		for i := 1; i <= records; i++ {
			fmt.Fprintf(&p, price, i, i, i)
		}
		if err := os.WriteFile(filepath.Join(dir, "prices.jsonl"), []byte(p.String()), 0o644); err != nil {
			t.Fatal(err)
		}
		return dir
	}
	for _, c := range []struct {
		name   string
		dir    string
		reason string
		rc     int
	}{
		{"pass", write(t, 777001, 4), "ok", 0},
		{"not enough yet", write(t, 777001, 3), "pending", 64},
		{"another account", write(t, 42, 4), "wrong_account", 25},
	} {
		t.Run(c.name, func(t *testing.T) {
			cmd := exec.Command(os.Args[0], "-check-live", "-out", c.dir, "-expect-login", "777001",
				"-expect-server", "Broker-Live", "-min-fresh", "3", "-conn", "1")
			cmd.Env = append(os.Environ(), "GOLDREC_TEST_RUN_MAIN=1")
			out, err := cmd.Output()
			rc := 0
			var ee *exec.ExitError
			if errors.As(err, &ee) {
				rc = ee.ExitCode()
			} else if err != nil {
				t.Fatal(err)
			}
			lines := strings.Split(strings.TrimSpace(string(out)), "\n")
			if len(lines) != 1 || !strings.HasPrefix(lines[0], "reason="+c.reason+" ") || rc != c.rc {
				t.Fatalf("rc %d, output %q; want rc %d, one reason=%s line", rc, out, c.rc, c.reason)
			}
		})
	}
}
