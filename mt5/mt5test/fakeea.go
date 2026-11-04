// Package mt5test provides a fake GoBridge EA for testing code that uses the
// mt5 package without a MetaTrader terminal.
package mt5test

import (
	"encoding/json"
	"net"
	"sync"

	"github.com/condrove10/gomql5/protocol"
)

// Handler answers one request. Return (result, nil) for success or
// (nil, *protocol.Error) for failure. Returning NoReply sends nothing.
type Handler func(params map[string]any) (any, *protocol.Error)

// NoReply is a sentinel error: the fake EA swallows the request (to test timeouts).
var NoReply = &protocol.Error{Code: 0, Message: "no reply"}

// FakeEA dials a mt5.Server and behaves like GoBridge.mq5.
type FakeEA struct {
	Hello    protocol.Hello
	Handlers map[string]Handler

	conn    net.Conn
	writeMu sync.Mutex
	mu      sync.Mutex
	got     []map[string]any
	done    chan struct{}
}

// New returns a FakeEA with a default hello and a ping handler.
func New(token string) *FakeEA {
	return &FakeEA{
		Hello: protocol.Hello{Type: protocol.TypeHello, Proto: protocol.Version, Token: token,
			EAVersion: "test", Build: 5000, Login: 12345, Server: "Demo-Server", Company: "Test Broker"},
		Handlers: map[string]Handler{
			"ping": func(map[string]any) (any, *protocol.Error) { return map[string]any{"time": 1700000000}, nil },
		},
		done: make(chan struct{}),
	}
}

// Dial connects, sends hello and starts serving requests.
func (f *FakeEA) Dial(addr string) error {
	c, err := net.Dial("tcp", addr)
	if err != nil {
		return err
	}
	f.conn = c
	b, _ := json.Marshal(f.Hello)
	if err := f.send(b); err != nil {
		return err
	}
	go f.serve()
	return nil
}

// Requests returns every request received so far (as decoded flat objects).
func (f *FakeEA) Requests() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]map[string]any(nil), f.got...)
}

// SendRaw writes an arbitrary frame (to inject events or malformed data).
func (f *FakeEA) SendRaw(b []byte) error { return f.send(b) }

// SendEvent pushes an event message.
func (f *FakeEA) SendEvent(event string, data any) error {
	d, err := json.Marshal(data)
	if err != nil {
		return err
	}
	b, _ := json.Marshal(protocol.Envelope{Type: protocol.TypeEvent, Event: event, Data: d})
	return f.send(b)
}

// Close disconnects.
func (f *FakeEA) Close() error {
	if f.conn == nil {
		return nil
	}
	err := f.conn.Close()
	<-f.done
	return err
}

func (f *FakeEA) send(b []byte) error {
	f.writeMu.Lock()
	defer f.writeMu.Unlock()
	return protocol.WriteFrame(f.conn, b)
}

func (f *FakeEA) serve() {
	defer close(f.done)
	for {
		b, err := protocol.ReadFrame(f.conn, 0)
		if err != nil {
			return
		}
		var req map[string]any
		if err := json.Unmarshal(b, &req); err != nil {
			return
		}
		f.mu.Lock()
		f.got = append(f.got, req)
		f.mu.Unlock()

		id := uint64(req["id"].(float64))
		method, _ := req["method"].(string)
		h, ok := f.Handlers[method]
		var res any
		var perr *protocol.Error
		if !ok {
			perr = &protocol.Error{Code: protocol.ErrCodeUnsupported, Message: "unknown method " + method}
		} else {
			res, perr = h(req)
		}
		if perr == NoReply {
			continue
		}
		env := map[string]any{"type": protocol.TypeResponse, "id": id, "ok": perr == nil}
		if perr != nil {
			env["error"] = perr
		} else {
			env["result"] = res
		}
		out, _ := json.Marshal(env)
		if err := f.send(out); err != nil {
			return
		}
	}
}
