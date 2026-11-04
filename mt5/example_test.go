package mt5_test

// Runnable examples. Each starts a FakeEA (mt5/mt5test) in place of the real
// terminal, so `go test ./mt5` executes them and checks their output. The
// README's snippets are taken from here.

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"time"

	"github.com/condrove10/gomql5/mt5"
	"github.com/condrove10/gomql5/mt5/mt5test"
	"github.com/condrove10/gomql5/protocol"
)

var quiet = slog.New(slog.NewTextHandler(io.Discard, nil))

// fakeTerminal starts a FakeEA with a few canned answers and dials srv.
func fakeTerminal(srv *mt5.Server, token string) *mt5test.FakeEA {
	ea := mt5test.New(token)
	ea.Hello.Login, ea.Hello.Server = 1234567, "Broker-Demo"
	ea.Handlers["account_info"] = func(map[string]any) (any, *protocol.Error) {
		return json.RawMessage(`{"login":1234567,"server":"Broker-Demo","currency":"USD","balance":10000,"equity":10000,"leverage":100}`), nil
	}
	ea.Handlers["symbol_info_tick"] = func(p map[string]any) (any, *protocol.Error) {
		if p["symbol"] != "XAUUSD" {
			return nil, &protocol.Error{Code: protocol.ErrCodeNotFound, Message: fmt.Sprintf("symbol '%v' not found", p["symbol"])}
		}
		return json.RawMessage(`{"time":1762268400,"bid":4001.12,"ask":4001.45,"time_msc":1762268400123,"flags":6}`), nil
	}
	ea.Handlers["copy_rates_from_pos"] = func(map[string]any) (any, *protocol.Error) {
		return json.RawMessage(`[[1762264800,3995.1,4003.9,3990.0,4001.2,5120,25,0],[1762268400,4001.2,4002.0,3999.5,4001.3,830,25,0]]`), nil
	}
	ea.Handlers["subscribe_ticks"] = func(map[string]any) (any, *protocol.Error) { return true, nil }
	ea.Handlers["order_send"] = func(p map[string]any) (any, *protocol.Error) {
		// The trade server rejects the order: not a Go error, a retcode.
		return map[string]any{"retcode": int(mt5.TradeRetcodeNoMoney), "comment": "No money"}, nil
	}
	if err := ea.Dial(srv.Addr().String()); err != nil {
		panic(err)
	}
	return ea
}

// The basic flow: listen, wait for the EA, query.
func Example() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	srv, err := mt5.Listen("127.0.0.1:0", mt5.Config{Token: "secret", Logger: quiet})
	if err != nil {
		panic(err)
	}
	defer srv.Close()
	ea := fakeTerminal(srv, "secret") // in production: the GoBridge EA in MT5
	defer ea.Close()

	term, err := srv.Accept(ctx) // one EA = one terminal/account
	if err != nil {
		panic(err)
	}
	defer term.Close()
	h := term.Hello()
	fmt.Println("connected:", h.Login, h.Server)

	ai, _ := term.AccountInfo(ctx)
	fmt.Printf("balance %.2f %s, leverage 1:%d\n", ai.Balance, ai.Currency, ai.Leverage)

	tk, _ := term.SymbolInfoTick(ctx, "XAUUSD")
	fmt.Printf("XAUUSD bid=%.2f ask=%.2f at %s (broker time)\n", tk.Bid, tk.Ask,
		mt5.ServerTimeMsc(tk.TimeMsc).Format("2006-01-02 15:04:05.000"))

	bars, _ := term.CopyRatesFromPos(ctx, "XAUUSD", mt5.TimeframeH1, 0, 2)
	for _, b := range bars {
		fmt.Printf("%s O=%.1f C=%.1f\n", mt5.ServerTime(b.Time).Format("15:04"), b.Open, b.Close)
	}
	// Output:
	// connected: 1234567 Broker-Demo
	// balance 10000.00 USD, leverage 1:100
	// XAUUSD bid=4001.12 ask=4001.45 at 2025-11-04 15:00:00.123 (broker time)
	// 14:00 O=3995.1 C=4001.2
	// 15:00 O=4001.2 C=4001.3
}

// Errors from the EA are *protocol.Error with a code; trade rejections are not
// errors but a retcode, as in the Python package.
func Example_errors() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv, _ := mt5.Listen("127.0.0.1:0", mt5.Config{Token: "secret", Logger: quiet})
	defer srv.Close()
	ea := fakeTerminal(srv, "secret")
	defer ea.Close()
	term, _ := srv.Accept(ctx)
	defer term.Close()

	_, err := term.SymbolInfoTick(ctx, "NOPE")
	var pe *protocol.Error
	if errors.As(err, &pe) && pe.Code == protocol.ErrCodeNotFound {
		fmt.Println("not found:", pe.Message)
	}

	res, err := term.OrderSend(ctx, mt5.TradeRequest{Action: mt5.TradeActionDeal, Symbol: "XAUUSD", Volume: 0.01,
		Type: mt5.OrderTypeBuy, TypeFilling: mt5.OrderFillingIoc, Deviation: 20})
	if err == nil && res.Retcode != mt5.TradeRetcodeDone {
		fmt.Println("rejected:", res.Retcode == mt5.TradeRetcodeNoMoney, res.Comment)
	}

	// A method the Go package has no wrapper for yet: Call it directly.
	err = term.Call(ctx, "market_book_get", map[string]any{"symbol": "XAUUSD"}, nil)
	if errors.As(err, &pe) && pe.Code == protocol.ErrCodeUnsupported {
		fmt.Println("EA does not support it yet")
	}
	// Output:
	// not found: symbol 'NOPE' not found
	// rejected: true No money
	// EA does not support it yet
}

// Streaming ticks. Subscriptions are per connection: re-subscribe after the
// EA reconnects (a reconnect is a new Terminal from Accept).
func ExampleTerminal_SubscribeTicks() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv, _ := mt5.Listen("127.0.0.1:0", mt5.Config{Token: "secret", Logger: quiet})
	defer srv.Close()
	ea := fakeTerminal(srv, "secret")
	defer ea.Close()
	term, _ := srv.Accept(ctx)
	defer term.Close()

	if err := term.SubscribeTicks(ctx, "XAUUSD"); err != nil {
		panic(err)
	}
	// (the fake EA pushes two ticks; the real one pushes every price change)
	ea.SendEvent("tick", map[string]any{"symbol": "XAUUSD", "bid": 4001.10, "ask": 4001.40, "time_msc": 1762268400100})
	ea.SendEvent("tick", map[string]any{"symbol": "XAUUSD", "bid": 4001.20, "ask": 4001.50, "time_msc": 1762268400200})
	for i := 0; i < 2; i++ {
		select {
		case tk := <-term.Ticks():
			fmt.Printf("%s %.2f/%.2f\n", tk.Symbol, tk.Bid, tk.Ask)
		case <-term.Done(): // connection lost: Accept the next one and re-subscribe
			fmt.Println("disconnected:", term.Err())
			return
		}
	}
	fmt.Println("dropped:", term.DroppedTicks())
	// Output:
	// XAUUSD 4001.10/4001.40
	// XAUUSD 4001.20/4001.50
	// dropped: 0
}

// A long-running app serves terminals as they (re)connect.
func ExampleServer_Accept() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv, _ := mt5.Listen("127.0.0.1:0", mt5.Config{Token: "secret", Logger: quiet})
	defer srv.Close()

	go func() { // the EA connects, drops, and reconnects
		ea := fakeTerminal(srv, "secret")
		time.Sleep(50 * time.Millisecond)
		ea.Close()
		ea2 := fakeTerminal(srv, "secret")
		time.Sleep(50 * time.Millisecond)
		ea2.Close()
	}()
	for n := 1; n <= 2; n++ {
		term, err := srv.Accept(ctx)
		if err != nil {
			return
		}
		fmt.Println("session", n, "login", term.Hello().Login)
		<-term.Done() // serve until it disconnects
		fmt.Println("session", n, "ended:", errors.Is(term.Err(), mt5.ErrClosed))
	}
	// Output:
	// session 1 login 1234567
	// session 1 ended: true
	// session 2 login 1234567
	// session 2 ended: true
}

// TLS: wrap the listener. (The EA side is on the roadmap; compile-only example.)
func ExampleNewServer_tls() {
	var cert tls.Certificate // load with tls.LoadX509KeyPair
	ln, err := net.Listen("tcp", ":7788")
	if err != nil {
		return
	}
	srv, err := mt5.NewServer(tls.NewListener(ln, &tls.Config{Certificates: []tls.Certificate{cert}}), mt5.Config{Token: "secret"})
	if err != nil {
		return
	}
	defer srv.Close()
}
