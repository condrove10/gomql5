package myfxbook

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func load(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func hasFlag(n Normalized, f string) bool {
	for _, q := range n.Quality {
		if q == f {
			return true
		}
	}
	return false
}

func TestNormalizeKeepsSuppliedText(t *testing.T) {
	r, err := Parse(load(t, "synthetic-outlook-ok.json"))
	if err != nil {
		t.Fatal(err)
	}
	if r.Error || len(r.Symbols) != 2 || len(r.General) == 0 {
		t.Fatalf("bad parse: %+v", r)
	}
	xs := r.Find("xauusd")
	if len(xs) != 1 {
		t.Fatalf("Find: %d", len(xs))
	}
	n := Normalize(xs[0])
	if n.Quarantined || len(n.Quality) != 0 {
		t.Fatalf("clean fixture flagged: %v", n.Quality)
	}
	// 836.10 must stay "836.10", not 836.1: the vendor's text is the record.
	if *n.Supplied.LongVolume != "836.10" || *n.Supplied.TotalPositions != "11491" {
		t.Fatalf("supplied text changed: %s %s", *n.Supplied.LongVolume, *n.Supplied.TotalPositions)
	}
	if got := *n.Derived.LongVolumeShare; got < 0.6200 || got > 0.6201 { // 836.10/1348.44
		t.Fatalf("long volume share %v", got)
	}
	if got := *n.Derived.LongCountShare; got < 0.6362 || got > 0.6363 { // 7311/11491
		t.Fatalf("long count share %v", got)
	}
	if !*n.Derived.TotalMatchesCount || *n.Derived.SumPositions != 11491 {
		t.Fatal("total should match")
	}
}

func TestNormalizeQuirks(t *testing.T) {
	r, err := Parse(load(t, "synthetic-outlook-quirks.json"))
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := r.Extra["newTopLevel"]; !ok {
		t.Fatal("unknown top-level key not kept")
	}
	n := Normalize(r.Symbols[0])
	for _, f := range []string{"numeric_string:shortPercentage", "null:avgShortPrice", "zero_denominator:volume",
		"total_mismatch", "percentage_sum_off", "unknown_field:newField"} {
		if !hasFlag(n, f) {
			t.Errorf("missing flag %s in %v", f, n.Quality)
		}
	}
	if !n.Quarantined {
		t.Error("null average price must quarantine")
	}
	if n.Supplied.AvgShortPrice != nil {
		t.Error("null must not become a value")
	}
	if n.Derived.LongVolumeShare != nil {
		t.Error("zero denominator must be unavailable, not 0")
	}
	if *n.Supplied.ShortPercentage != "38" || *n.Supplied.TotalPositions != "20000" {
		t.Error("supplied values must be kept even when inconsistent")
	}
}

func TestNormalizeRejects(t *testing.T) {
	cases := map[string]string{
		`"NaN"`:   "invalid:longVolume",
		`"Inf"`:   "invalid:longVolume",
		`"0x10"`:  "invalid:longVolume",
		`"+5"`:    "invalid:longVolume",
		`".5"`:    "invalid:longVolume",
		`"5."`:    "invalid:longVolume",
		`"0x1p3"`: "invalid:longVolume",
		`"abc"`:   "invalid:longVolume",
		`true`:    "invalid:longVolume",
		`""`:      "invalid:longVolume",
		`-5`:      "negative:longVolume",
		`"1e2"`:   "numeric_string:longVolume",
		`{"a":1}`: "invalid:longVolume",
	}
	for raw, want := range cases {
		s := RawSymbol{Name: "XAUUSD", Fields: map[string]json.RawMessage{}}
		json.Unmarshal(load(t, "synthetic-outlook-changed.json"), new(any))
		r, _ := Parse(load(t, "synthetic-outlook-changed.json"))
		for k, v := range r.Symbols[0].Fields {
			s.Fields[k] = v
		}
		s.Fields["longVolume"] = json.RawMessage(raw)
		n := Normalize(s)
		if !hasFlag(n, want) {
			t.Errorf("%s: want %s, got %v", raw, want, n.Quality)
		}
		if strings.HasPrefix(want, "invalid") && (!n.Quarantined || n.Supplied.LongVolume != nil) {
			t.Errorf("%s: invalid value must quarantine and stay nil", raw)
		}
	}
	s := RawSymbol{Name: "XAUUSD", Fields: map[string]json.RawMessage{"longPositions": json.RawMessage("1.5")}}
	if n := Normalize(s); !hasFlag(n, "non_integer:longPositions") || !hasFlag(n, "missing:longVolume") || !n.Quarantined {
		t.Errorf("got %v", n.Quality)
	}
}

func TestParseErrors(t *testing.T) {
	for _, b := range []string{``, `null`, `[]`, `<html>`, `{"message":"x"}`, `{"error":"no"}`, `{"error":false,"symbols":{"a":1}}`, `{"error":false,"session":5}`} {
		if _, err := Parse([]byte(b)); err == nil {
			t.Errorf("%q: want error", b)
		}
	}
	r, err := Parse([]byte(`{"error":true,"message":"Invalid session."}`))
	if err != nil || !r.Error || r.Message != "Invalid session." {
		t.Fatalf("%+v %v", r, err)
	}
}

// fakeVendor imitates the API surface the client uses. It records each query
// so tests can assert that secrets never leave via other channels.
type fakeVendor struct {
	mu       sync.Mutex
	logins   int
	outlooks int
	session  string
	outlook  func(n int) (int, string) // status, body
	queries  []string
}

func (f *fakeVendor) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.queries = append(f.queries, r.URL.RawQuery)
	w.Header().Set("Content-Type", "application/json;charset=utf-8")
	switch r.URL.Path {
	case "/api/login.json":
		f.logins++
		if r.URL.Query().Get("email") == "" || r.URL.Query().Get("password") == "" {
			w.Write([]byte(`{"error":true,"message":"Required fields missing.","session":""}`))
			return
		}
		if r.URL.Query().Get("password") != "pa ss&word" {
			w.Write([]byte(`{"error":true,"message":"Invalid email or password.","session":""}`))
			return
		}
		f.session = "SeSs" + string(rune('A'+f.logins))
		w.Write([]byte(`{"error":false,"message":"","session":"` + f.session + `"}`))
	case "/api/get-community-outlook.json":
		f.outlooks++
		if r.URL.Query().Get("session") != f.session || f.session == "" {
			w.Write([]byte(`{"error":true,"message":"Invalid session."}`))
			return
		}
		code, body := f.outlook(f.outlooks)
		w.WriteHeader(code)
		w.Write([]byte(body))
	case "/api/logout.json":
		f.session = ""
		w.Write([]byte(`{"error":false,"message":""}`))
	default:
		http.NotFound(w, r)
	}
}

func newClient(t *testing.T, v *fakeVendor, budget int) (*Client, *httptest.Server) {
	t.Helper()
	srv := httptest.NewServer(v)
	t.Cleanup(srv.Close)
	l, err := OpenLedger("", budget)
	if err != nil {
		t.Fatal(err)
	}
	return &Client{BaseURL: srv.URL + "/api", Email: "me@example.com", Password: "pa ss&word", Ledger: l, MinRelogin: time.Hour}, srv
}

func TestFetchLoginAndOutlook(t *testing.T) {
	ok := string(load(t, "synthetic-outlook-ok.json"))
	v := &fakeVendor{outlook: func(int) (int, string) { return 200, ok }}
	c, _ := newClient(t, v, 10)
	atts, r := c.Fetch(context.Background())
	if len(atts) != 2 || atts[0].Method != "login" || atts[1].Method != "outlook" || atts[1].Status != StatusOK || r == nil {
		t.Fatalf("%+v", atts)
	}
	if atts[0].Body != nil || atts[0].BodySHA256 != "" {
		t.Fatal("login body (holds the session) must not be retained")
	}
	if atts[1].BodySHA256 == "" || len(atts[1].Body) == 0 || atts[1].BudgetUsed != 2 || atts[1].BudgetLeft != 8 {
		t.Fatalf("outlook attempt: %+v", atts[1])
	}
	// Second fetch reuses the session: no login.
	atts, _ = c.Fetch(context.Background())
	if len(atts) != 1 || v.logins != 1 {
		t.Fatalf("session not reused: %d attempts, %d logins", len(atts), v.logins)
	}
}

func TestFetchReloginOnceThenThrottle(t *testing.T) {
	ok := string(load(t, "synthetic-outlook-ok.json"))
	v := &fakeVendor{outlook: func(int) (int, string) { return 200, ok }}
	c, _ := newClient(t, v, 100)
	now := time.Date(2026, 11, 4, 0, 0, 0, 0, time.UTC)
	c.now = func() time.Time { return now }
	c.Fetch(context.Background())

	// Session expires (vendor forgets it). An hour later: one re-login, success.
	v.mu.Lock()
	v.session = "other"
	v.mu.Unlock()
	now = now.Add(2 * time.Hour)
	atts, r := c.Fetch(context.Background())
	if r == nil || len(atts) != 3 || atts[0].Status != StatusSession || atts[1].Method != "login" || atts[2].Status != StatusOK {
		t.Fatalf("re-login sequence: %+v", atts)
	}

	// Session rejected again right away (e.g. bound to another IP): the
	// re-login is throttled instead of looping.
	v.mu.Lock()
	v.session = "other"
	v.mu.Unlock()
	now = now.Add(time.Minute)
	for i := 0; i < 5; i++ {
		atts, r = c.Fetch(context.Background())
	}
	if r != nil || atts[len(atts)-1].Status != StatusLoginThrottled {
		t.Fatalf("want throttled, got %+v", atts)
	}
	if v.logins != 2 {
		t.Fatalf("login loop: %d logins", v.logins)
	}
}

func TestFetchStatuses(t *testing.T) {
	cases := []struct {
		code int
		body string
		want string
	}{
		{403, `<html><script src="https://challenges.cloudflare.com/x"></script></html>`, StatusHTTP},
		{200, `<html>`, StatusParse},
		{200, `{"error":true,"message":"Max requests reached"}`, StatusApp},
		{502, ``, StatusHTTP},
	}
	for _, tc := range cases {
		v := &fakeVendor{outlook: func(int) (int, string) { return tc.code, tc.body }}
		c, _ := newClient(t, v, 10)
		atts, r := c.Fetch(context.Background())
		last := atts[len(atts)-1]
		if last.Status != tc.want || r != nil && tc.want != StatusApp {
			t.Errorf("%d %q: got %s", tc.code, tc.body, last.Status)
		}
		if tc.code == 403 && !strings.Contains(last.Message, "Cloudflare") {
			t.Errorf("challenge not identified: %q", last.Message)
		}
	}
}

func TestBudgetStopsRequestsAndSurvivesRestart(t *testing.T) {
	ok := string(load(t, "synthetic-outlook-ok.json"))
	v := &fakeVendor{outlook: func(int) (int, string) { return 200, ok }}
	srv := httptest.NewServer(v)
	defer srv.Close()
	path := filepath.Join(t.TempDir(), "ledger.log")
	l, _ := OpenLedger(path, 3)
	c := &Client{BaseURL: srv.URL + "/api", Email: "a@b.c", Password: "pa ss&word", Ledger: l}
	c.Fetch(context.Background()) // login + outlook = 2
	c.Fetch(context.Background()) // outlook = 3
	atts, _ := c.Fetch(context.Background())
	if atts[0].Status != StatusBudget || v.outlooks != 2 {
		t.Fatalf("budget not enforced: %+v, %d outlooks sent", atts, v.outlooks)
	}
	l.Close()

	// Restart: a new ledger on the same file still sees 3 used.
	l2, _ := OpenLedger(path, 3)
	defer l2.Close()
	if used, left := l2.Used(); used != 3 || left != 0 {
		t.Fatalf("after restart used=%d left=%d", used, left)
	}
	// Torn last line (crash mid-write) is ignored, earlier lines still count.
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString("2026-11-0")
	f.Close()
	l3, _ := OpenLedger(path, 3)
	defer l3.Close()
	if used, _ := l3.Used(); used != 3 {
		t.Fatalf("torn line: used=%d", used)
	}
	// Entries older than the window no longer count.
	l3.now = func() time.Time { return time.Now().Add(25 * time.Hour) }
	if used, _ := l3.Used(); used != 0 {
		t.Fatalf("window: used=%d", used)
	}
}

func TestSecretsRedacted(t *testing.T) {
	v := &fakeVendor{outlook: func(int) (int, string) { return 200, `{}` }}
	c, srv := newClient(t, v, 10)
	// Transport error: url.Error text would include the full query string.
	c.HTTP = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return nil, &json.SyntaxError{}
	})}
	atts, _ := c.Fetch(context.Background())
	_ = srv
	for _, a := range atts {
		if strings.Contains(a.Message, "login.json?") || strings.Contains(a.Message, "email=") {
			t.Fatalf("transport error carries the request URL: %q", a.Message)
		}
		b, _ := json.Marshal(a)
		for _, s := range []string{"pa ss&word", "pa+ss%26word", "me@example.com", "me%40example.com"} {
			if strings.Contains(string(b)+a.Message, s) {
				t.Fatalf("secret %q leaked in %s", s, b)
			}
		}
	}
	// And the vendor received the password correctly encoded (it compares exactly).
	c.HTTP = nil
	c.mu.Lock()
	c.lastLogin = time.Time{}
	c.mu.Unlock()
	if atts, _ := c.Fetch(context.Background()); atts[0].Method != "login" || atts[0].Status != StatusOK {
		t.Fatalf("login with special characters failed: %+v", atts)
	}
	c.mu.Lock()
	c.session = "S3SSION"
	c.mu.Unlock()
	if got := c.redact("x session=S3SSION y"); strings.Contains(got, "S3SSION") {
		t.Fatal(got)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestNoCredentials(t *testing.T) {
	v := &fakeVendor{outlook: func(int) (int, string) { return 200, `{}` }}
	c, _ := newClient(t, v, 10)
	c.Email, c.Password = "", ""
	atts, r := c.Fetch(context.Background())
	if r != nil || atts[0].Status != StatusNoCredentials || len(v.queries) != 0 {
		t.Fatalf("%+v, %d requests", atts, len(v.queries))
	}
}

func TestCapturedVendorErrors(t *testing.T) {
	for _, f := range []string{"captured-2026-11-04-outlook-invalid-session.json", "captured-2026-11-04-login-missing-fields.json",
		"captured-2026-11-04-by-country-invalid-session.json"} {
		body := string(load(t, f))
		r, err := Parse([]byte(body))
		if err != nil || !r.Error || r.Message == "" {
			t.Fatalf("%s: %+v %v", f, r, err)
		}
		v := &fakeVendor{outlook: func(int) (int, string) { return 200, body }}
		c, _ := newClient(t, v, 10)
		atts, resp := c.Fetch(context.Background())
		want := StatusApp
		if strings.Contains(f, "invalid-session") {
			want = StatusSession
		}
		if len(atts) < 2 || atts[1].Method != "outlook" || atts[1].Status != want || resp != nil && want == StatusSession {
			t.Errorf("%s: attempts %+v, want outlook %s", f, atts, want)
		}
	}
}
