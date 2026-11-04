// Package mt5 is a Go client for MetaTrader 5.
//
// The MT5 terminal runs the GoBridge Expert Advisor (mql5/Experts/GoBridge),
// which connects out to a Server started by your Go application. MQL5 sockets
// can only connect, never listen, so the Go side is the TCP server. Each
// accepted connection is one Terminal (one MT5 terminal = one trading account).
//
// The API mirrors the official MetaTrader5 Python package: AccountInfo,
// SymbolInfoTick, CopyRatesRange, OrderSend, PositionsGet, HistoryDealsGet...
package mt5

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"
	"time"

	"github.com/condrove10/gomql5/protocol"
)

// Config configures a Server.
type Config struct {
	// Token is the shared secret the EA must present in its hello message.
	// Required unless AllowNoToken is set.
	Token string
	// AllowNoToken accepts any EA when Token is empty. Only for local testing.
	AllowNoToken bool
	// HandshakeTimeout bounds the wait for the EA's hello. Default 10s.
	HandshakeTimeout time.Duration
	// RequestTimeout is applied to calls whose context has no deadline. Default 30s.
	RequestTimeout time.Duration
	// PingInterval is the heartbeat period; a missed heartbeat closes the
	// Terminal. Default 15s; negative disables.
	PingInterval time.Duration
	// MaxFrame is the largest accepted frame in bytes. Default protocol.DefaultMaxFrame.
	MaxFrame int
	// TickBuffer is the capacity of Terminal.Ticks(). Default 4096. When full,
	// new ticks are dropped and counted (Terminal.DroppedTicks).
	TickBuffer int
	// Logger receives connection-level logs. Default slog.Default().
	Logger *slog.Logger
}

func (c *Config) setDefaults() {
	if c.HandshakeTimeout == 0 {
		c.HandshakeTimeout = 10 * time.Second
	}
	if c.RequestTimeout == 0 {
		c.RequestTimeout = 30 * time.Second
	}
	if c.PingInterval == 0 {
		c.PingInterval = 15 * time.Second
	}
	if c.MaxFrame <= 0 {
		c.MaxFrame = protocol.DefaultMaxFrame
	}
	if c.TickBuffer <= 0 {
		c.TickBuffer = 4096
	}
	if c.Logger == nil {
		c.Logger = slog.Default()
	}
}

// Errors returned by the client.
var (
	ErrClosed       = errors.New("mt5: terminal connection closed")
	ErrServerClosed = errors.New("mt5: server closed")
	ErrAuth         = errors.New("mt5: handshake rejected")
)

// Server accepts connections from GoBridge EAs.
type Server struct {
	ln        net.Listener
	cfg       Config
	terminals chan *Terminal
	done      chan struct{}
	closeOnce sync.Once
	wg        sync.WaitGroup
}

// Listen starts a plain-TCP Server on addr (e.g. ":7788").
func Listen(addr string, cfg Config) (*Server, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	s, err := NewServer(ln, cfg)
	if err != nil {
		ln.Close()
		return nil, err
	}
	return s, nil
}

// NewServer serves on an existing listener. Pass tls.NewListener(...) here to
// add TLS (the EA side supports TLS via SocketTlsHandshake; see docs/ROADMAP.md).
func NewServer(ln net.Listener, cfg Config) (*Server, error) {
	if cfg.Token == "" && !cfg.AllowNoToken {
		return nil, errors.New("mt5: Config.Token is required (or set AllowNoToken for local testing)")
	}
	cfg.setDefaults()
	s := &Server{ln: ln, cfg: cfg, terminals: make(chan *Terminal), done: make(chan struct{})}
	s.wg.Add(1)
	go s.acceptLoop()
	return s, nil
}

// Addr returns the listen address.
func (s *Server) Addr() net.Addr { return s.ln.Addr() }

// Accept waits for the next EA that completes the handshake.
func (s *Server) Accept(ctx context.Context) (*Terminal, error) {
	select {
	case t := <-s.terminals:
		return t, nil
	case <-s.done:
		return nil, ErrServerClosed
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// Close stops accepting. Already accepted Terminals stay open.
func (s *Server) Close() error {
	var err error
	s.closeOnce.Do(func() {
		close(s.done)
		err = s.ln.Close()
	})
	s.wg.Wait()
	return err
}

func (s *Server) acceptLoop() {
	defer s.wg.Done()
	for {
		c, err := s.ln.Accept()
		if err != nil {
			select {
			case <-s.done:
				return
			default:
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				time.Sleep(50 * time.Millisecond)
				continue
			}
			s.cfg.Logger.Error("mt5: accept failed", "err", err)
			return
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			// Abort a pending handshake when the server closes, so Close
			// doesn't wait for HandshakeTimeout.
			hsDone := make(chan struct{})
			go func() {
				select {
				case <-s.done:
					c.Close()
				case <-hsDone:
				}
			}()
			t, err := s.handshake(c)
			close(hsDone)
			if err != nil {
				s.cfg.Logger.Warn("mt5: handshake failed", "remote", c.RemoteAddr().String(), "err", err)
				c.Close()
				return
			}
			select {
			case s.terminals <- t:
			case <-s.done:
				t.Close()
			}
		}()
	}
}

func (s *Server) handshake(c net.Conn) (*Terminal, error) {
	_ = c.SetReadDeadline(time.Now().Add(s.cfg.HandshakeTimeout))
	b, err := protocol.ReadFrame(c, s.cfg.MaxFrame)
	if err != nil {
		return nil, err
	}
	_ = c.SetReadDeadline(time.Time{})
	var h protocol.Hello
	if err := json.Unmarshal(b, &h); err != nil {
		return nil, fmt.Errorf("decode hello: %w", err)
	}
	if h.Type != protocol.TypeHello {
		return nil, fmt.Errorf("%w: first message type %q, want hello", ErrAuth, h.Type)
	}
	if h.Proto != protocol.Version {
		return nil, fmt.Errorf("%w: protocol version %d, want %d", ErrAuth, h.Proto, protocol.Version)
	}
	if s.cfg.Token != "" && subtle.ConstantTimeCompare([]byte(h.Token), []byte(s.cfg.Token)) != 1 {
		return nil, fmt.Errorf("%w: bad token", ErrAuth)
	}
	h.Token = ""
	return newTerminal(c, h, s.cfg), nil
}

// Terminal is one connected MT5 terminal. All methods are safe for concurrent use.
type Terminal struct {
	conn    net.Conn
	hello   protocol.Hello
	cfg     Config
	writeMu sync.Mutex

	mu      sync.Mutex
	nextID  uint64
	pending map[uint64]chan *protocol.Envelope
	err     error

	ticks   chan Tick
	dropped uint64

	done      chan struct{}
	closeOnce sync.Once
}

func newTerminal(c net.Conn, h protocol.Hello, cfg Config) *Terminal {
	t := &Terminal{
		conn:    c,
		hello:   h,
		cfg:     cfg,
		pending: make(map[uint64]chan *protocol.Envelope),
		ticks:   make(chan Tick, cfg.TickBuffer),
		done:    make(chan struct{}),
	}
	go t.readLoop()
	if cfg.PingInterval > 0 {
		go t.pingLoop()
	}
	return t
}

// Hello returns what the EA announced at connect time (token removed).
func (t *Terminal) Hello() protocol.Hello { return t.hello }

// RemoteAddr returns the EA's address.
func (t *Terminal) RemoteAddr() net.Addr { return t.conn.RemoteAddr() }

// Ticks delivers tick events for symbols subscribed with SubscribeTicks.
// The channel is closed when the Terminal closes.
func (t *Terminal) Ticks() <-chan Tick { return t.ticks }

// DroppedTicks counts ticks discarded because Ticks() was full.
func (t *Terminal) DroppedTicks() uint64 {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.dropped
}

// Done is closed when the connection ends.
func (t *Terminal) Done() <-chan struct{} { return t.done }

// Err returns why the connection ended (nil while open).
func (t *Terminal) Err() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.err
}

// Close closes the connection.
func (t *Terminal) Close() error {
	t.fail(ErrClosed)
	return nil
}

func (t *Terminal) fail(err error) {
	t.closeOnce.Do(func() {
		t.mu.Lock()
		t.err = err
		pending := t.pending
		t.pending = nil
		t.mu.Unlock()
		t.conn.Close()
		for _, ch := range pending {
			close(ch)
		}
		close(t.done)
	})
}

func (t *Terminal) readLoop() {
	defer close(t.ticks)
	for {
		b, err := protocol.ReadFrame(t.conn, t.cfg.MaxFrame)
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
				err = ErrClosed
			}
			t.fail(err)
			return
		}
		var env protocol.Envelope
		if err := json.Unmarshal(b, &env); err != nil {
			t.fail(fmt.Errorf("mt5: decode message: %w", err))
			return
		}
		switch env.Type {
		case protocol.TypeResponse:
			t.mu.Lock()
			ch, ok := t.pending[env.ID]
			delete(t.pending, env.ID)
			t.mu.Unlock()
			if ok {
				ch <- &env // buffered(1); never blocks
			}
		case protocol.TypeEvent:
			t.handleEvent(&env)
		default:
			t.cfg.Logger.Warn("mt5: unknown message type", "type", env.Type)
		}
	}
}

func (t *Terminal) handleEvent(env *protocol.Envelope) {
	switch env.Event {
	case "tick":
		var tk Tick
		if err := json.Unmarshal(env.Data, &tk); err != nil {
			t.cfg.Logger.Warn("mt5: bad tick event", "err", err)
			return
		}
		select {
		case t.ticks <- tk:
		default:
			t.mu.Lock()
			t.dropped++
			t.mu.Unlock()
		}
	case "log":
		t.cfg.Logger.Info("mt5: ea log", "login", t.hello.Login, "msg", string(env.Data))
	default:
		t.cfg.Logger.Debug("mt5: unhandled event", "event", env.Event)
	}
}

func (t *Terminal) pingLoop() {
	tk := time.NewTicker(t.cfg.PingInterval)
	defer tk.Stop()
	for {
		select {
		case <-t.done:
			return
		case <-tk.C:
			ctx, cancel := context.WithTimeout(context.Background(), t.cfg.PingInterval)
			err := t.Call(ctx, "ping", nil, nil)
			cancel()
			if err != nil && !errors.Is(err, ErrClosed) {
				t.fail(fmt.Errorf("mt5: heartbeat failed: %w", err))
				return
			}
		}
	}
}

// Call sends a raw request and decodes the result into out (if non-nil).
// Typed wrappers (AccountInfo, OrderSend, ...) are built on it; use Call
// directly for methods added to the EA before the Go wrapper exists.
// A failed request returns *protocol.Error.
func (t *Terminal) Call(ctx context.Context, method string, params map[string]any, out any) error {
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, t.cfg.RequestTimeout)
		defer cancel()
	}
	ch := make(chan *protocol.Envelope, 1)
	t.mu.Lock()
	if t.pending == nil {
		err := t.err
		t.mu.Unlock()
		return err
	}
	t.nextID++
	id := t.nextID
	t.pending[id] = ch
	t.mu.Unlock()

	unregister := func() {
		t.mu.Lock()
		if t.pending != nil {
			delete(t.pending, id)
		}
		t.mu.Unlock()
	}

	payload, err := json.Marshal(protocol.Request{ID: id, Method: method, Params: params})
	if err != nil {
		unregister()
		return err
	}
	t.writeMu.Lock()
	if dl, ok := ctx.Deadline(); ok {
		_ = t.conn.SetWriteDeadline(dl)
	}
	err = protocol.WriteFrame(t.conn, payload)
	t.writeMu.Unlock()
	if err != nil {
		unregister()
		t.fail(fmt.Errorf("mt5: write: %w", err))
		return err
	}

	select {
	case env, ok := <-ch:
		if !ok {
			return t.Err()
		}
		if !env.OK {
			if env.Error == nil {
				return &protocol.Error{Code: protocol.ErrCodeFail, Message: "request failed without error detail"}
			}
			return env.Error
		}
		if out == nil {
			return nil
		}
		if err := json.Unmarshal(env.Result, out); err != nil {
			return fmt.Errorf("mt5: decode %s result: %w", method, err)
		}
		return nil
	case <-ctx.Done():
		unregister()
		return fmt.Errorf("mt5: %s: %w", method, ctx.Err())
	}
}
