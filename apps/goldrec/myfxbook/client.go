package myfxbook

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// DefaultBaseURL is the documented API root.
const DefaultBaseURL = "https://www.myfxbook.com/api"

// Attempt statuses. Each request to the vendor produces exactly one Attempt.
const (
	StatusOK             = "ok"
	StatusTransport      = "transport_error" // no HTTP response (DNS, TLS, timeout, reset)
	StatusHTTP           = "http_error"      // non-2xx (e.g. a Cloudflare 403 challenge)
	StatusParse          = "parse_error"     // 2xx, but not a decodable envelope
	StatusApp            = "app_error"       // {"error":true,...} other than an invalid session
	StatusSession        = "session_invalid" // {"error":true,"message":"Invalid session."}
	StatusBudget         = "budget_exhausted"
	StatusLoginThrottled = "login_throttled" // a re-login was due but MinRelogin had not elapsed
	StatusNoCredentials  = "no_credentials"
)

// Attempt is the record of one request. It never contains the session, the
// email or the password. Body is set only for outlook responses (never for
// login, whose body carries the session).
type Attempt struct {
	Method      string    `json:"method"` // login | outlook | logout
	Start       time.Time `json:"request_start"`
	End         time.Time `json:"response_end"`
	DurationMs  int64     `json:"duration_ms"`
	HTTPStatus  int       `json:"http_status,omitempty"`
	Status      string    `json:"status"`
	Message     string    `json:"message,omitempty"` // vendor message or redacted transport error
	BodySHA256  string    `json:"body_sha256,omitempty"`
	BodyBytes   int       `json:"body_bytes,omitempty"`
	BudgetUsed  int       `json:"budget_used"`
	BudgetLeft  int       `json:"budget_remaining"`
	Body        []byte    `json:"-"`
	ContentType string    `json:"content_type,omitempty"`
}

// Client talks to the API. One Client must be the only poller for its
// account: the ledger and session are per process.
type Client struct {
	BaseURL    string
	HTTP       *http.Client
	Email      string
	Password   string
	Ledger     *Ledger
	UserAgent  string
	MinRelogin time.Duration // minimum spacing between logins; default 10m
	MaxBody    int64         // default 8 MiB

	mu        sync.Mutex
	session   string
	lastLogin time.Time
	now       func() time.Time
}

func (c *Client) clock() time.Time {
	if c.now != nil {
		return c.now()
	}
	return time.Now()
}

// Fetch returns the outlook, logging in first if needed. On "Invalid session."
// it re-logs in at most once per call and at most once per MinRelogin, so an
// expired or IP-rebound session cannot cause a login loop. All attempts made
// (login and outlook) are returned in order; the last one is the outlook
// attempt when one was sent.
func (c *Client) Fetch(ctx context.Context) ([]Attempt, *Response) {
	var atts []Attempt
	for try := 0; try < 2; try++ {
		if c.currentSession() == "" {
			a := c.login(ctx)
			atts = append(atts, a)
			if a.Status != StatusOK {
				return atts, nil
			}
		}
		a, r := c.get(ctx, "outlook", "get-community-outlook.json", url.Values{"session": {c.currentSession()}})
		atts = append(atts, a)
		if a.Status != StatusSession {
			return atts, r
		}
		c.mu.Lock()
		c.session = ""
		c.mu.Unlock()
	}
	return atts, nil
}

// Logout ends the session (best effort, counted against the budget).
func (c *Client) Logout(ctx context.Context) *Attempt {
	s := c.currentSession()
	if s == "" {
		return nil
	}
	a, _ := c.get(ctx, "logout", "logout.json", url.Values{"session": {s}})
	c.mu.Lock()
	c.session = ""
	c.mu.Unlock()
	return &a
}

func (c *Client) currentSession() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.session
}

func (c *Client) login(ctx context.Context) Attempt {
	a := c.loginOnce(ctx)
	if a.BudgetUsed == 0 && a.BudgetLeft == 0 && c.Ledger != nil {
		a.BudgetUsed, a.BudgetLeft = c.Ledger.Used()
	}
	return a
}

func (c *Client) loginOnce(ctx context.Context) Attempt {
	now := c.clock()
	if c.Email == "" || c.Password == "" {
		return Attempt{Method: "login", Start: now.UTC(), End: now.UTC(), Status: StatusNoCredentials,
			Message: "MYFXBOOK_EMAIL / MYFXBOOK_PASSWORD not set"}
	}
	min := c.MinRelogin
	if min == 0 {
		min = 10 * time.Minute
	}
	c.mu.Lock()
	last := c.lastLogin
	c.mu.Unlock()
	if !last.IsZero() && now.Sub(last) < min {
		return Attempt{Method: "login", Start: now.UTC(), End: now.UTC(), Status: StatusLoginThrottled,
			Message: fmt.Sprintf("last login %s ago, next allowed after %s", now.Sub(last).Round(time.Second), min)}
	}
	c.mu.Lock()
	c.lastLogin = now
	c.mu.Unlock()
	a, r := c.get(ctx, "login", "login.json", url.Values{"email": {c.Email}, "password": {c.Password}})
	a.Body, a.BodySHA256 = nil, "" // the login body holds the session: never archive it
	if a.Status == StatusOK {
		s := r.Session
		// The vendor's example sessions are URL-safe; if one arrives
		// percent-encoded, decode it so url.Values does not double-encode.
		if strings.Contains(s, "%") {
			if d, err := url.QueryUnescape(s); err == nil {
				s = d
			}
		}
		if s == "" {
			a.Status, a.Message = StatusApp, "login succeeded without a session"
		} else {
			c.mu.Lock()
			c.session = s
			c.mu.Unlock()
		}
	}
	return a
}

func (c *Client) get(ctx context.Context, method, path string, q url.Values) (Attempt, *Response) {
	a := Attempt{Method: method, Start: c.clock().UTC()}
	finish := func() {
		a.End = c.clock().UTC()
		a.DurationMs = a.End.Sub(a.Start).Milliseconds()
		if c.Ledger != nil {
			a.BudgetUsed, a.BudgetLeft = c.Ledger.Used()
		}
		a.Message = c.redact(a.Message)
	}
	if c.Ledger != nil {
		if err := c.Ledger.Reserve(method); err != nil {
			a.Status, a.Message = StatusBudget, err.Error()
			finish()
			return a, nil
		}
	}
	base := c.BaseURL
	if base == "" {
		base = DefaultBaseURL
	}
	u := strings.TrimRight(base, "/") + "/" + path + "?" + q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		a.Status, a.Message = StatusTransport, err.Error()
		finish()
		return a, nil
	}
	ua := c.UserAgent
	if ua == "" {
		ua = "gomql5-goldrec/0.1"
	}
	req.Header.Set("User-Agent", ua)
	req.Header.Set("Accept", "application/json")
	hc := c.HTTP
	if hc == nil {
		hc = &http.Client{Timeout: 30 * time.Second}
	}
	resp, err := hc.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err // drop the URL: it carries the session or the password
		}
		a.Status, a.Message = StatusTransport, err.Error()
		finish()
		return a, nil
	}
	defer resp.Body.Close()
	max := c.MaxBody
	if max == 0 {
		max = 8 << 20
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, max+1))
	a.HTTPStatus = resp.StatusCode
	a.ContentType = resp.Header.Get("Content-Type")
	if err != nil {
		a.Status, a.Message = StatusTransport, "reading body: "+err.Error()
		finish()
		return a, nil
	}
	if int64(len(body)) > max {
		a.Status, a.Message = StatusParse, fmt.Sprintf("body larger than %d bytes", max)
		finish()
		return a, nil
	}
	sum := sha256.Sum256(body)
	a.Body, a.BodySHA256, a.BodyBytes = body, hex.EncodeToString(sum[:]), len(body)
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		a.Status, a.Message = StatusHTTP, http.StatusText(resp.StatusCode)
		if strings.Contains(string(body), "challenges.cloudflare.com") {
			a.Message += " (Cloudflare challenge page)"
		}
		finish()
		return a, nil
	}
	r, err := Parse(body)
	if err != nil {
		a.Status, a.Message = StatusParse, err.Error()
		finish()
		return a, nil
	}
	a.Message = r.Message
	switch {
	case r.Error && strings.EqualFold(strings.TrimSpace(strings.TrimSuffix(r.Message, ".")), "invalid session"):
		a.Status = StatusSession
	case r.Error:
		a.Status = StatusApp
	default:
		a.Status = StatusOK
	}
	finish()
	return a, r
}

// redact removes secrets from s, in raw and URL-encoded form.
func (c *Client) redact(s string) string {
	c.mu.Lock()
	secrets := []string{c.session, c.Password, c.Email}
	c.mu.Unlock()
	for _, x := range secrets {
		if len(x) < 3 {
			continue
		}
		for _, form := range []string{x, url.QueryEscape(x), url.PathEscape(x)} {
			s = strings.ReplaceAll(s, form, "[REDACTED]")
		}
	}
	return s
}
