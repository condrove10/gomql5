package mt5_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/condrove10/gomql5/mt5"
	"github.com/condrove10/gomql5/mt5/mt5test"
)

// FuzzTickRateDecode: arbitrary JSON never panics, and an accepted array form
// had exactly 8 elements.
func FuzzTickRateDecode(f *testing.F) {
	for _, s := range []string{`[1,2,3,4,5,6,7,8]`, `{"bid":1,"time_msc":2}`, `[1,2]`, `[1e400,0,0,0,0,0,0,0]`,
		`["a",0,0,0,0,0,0,0]`, `null`, `[-1,-2,-3,-4,-5,-6,-7,-8]`, `[1.5,0,0,0,0,0,0,0]`} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		var tk mt5.Tick
		tkErr := json.Unmarshal(b, &tk)
		var r mt5.Rate
		rErr := json.Unmarshal(b, &r)
		var arr []json.RawMessage
		isArr := json.Unmarshal(b, &arr) == nil && len(b) > 0 && b[0] == '['
		if isArr && len(arr) != 8 && (tkErr == nil || rErr == nil) {
			t.Fatalf("array of %d accepted: %s", len(arr), b)
		}
	})
}

// FuzzServerFrames: whatever a (possibly hostile) EA sends after a valid
// hello, the Go side neither panics nor hangs: each frame is handled or the
// connection is closed, and calls fail rather than block.
func FuzzServerFrames(f *testing.F) {
	for _, s := range []string{`{"type":"res","id":1,"ok":true,"result":1}`, `{"type":"event","event":"tick","data":[1]}`,
		`{"type":"res","id":18446744073709551615,"ok":false,"error":null}`, `{"type":"event","event":"log","data":"x"}`,
		`not json`, `{"type":7}`, `{"type":"res","id":1,"ok":true}`, `[]`} {
		f.Add([]byte(s))
	}
	srv, err := mt5.Listen("127.0.0.1:0", mt5.Config{Token: token, PingInterval: -1, RequestTimeout: 200 * time.Millisecond})
	if err != nil {
		f.Fatal(err)
	}
	f.Cleanup(func() { srv.Close() })
	f.Fuzz(func(t *testing.T, frame []byte) {
		if len(frame) == 0 {
			return
		}
		ea := mt5test.New(token)
		if err := ea.Dial(srv.Addr().String()); err != nil {
			t.Fatal(err)
		}
		defer ea.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		term, err := srv.Accept(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer term.Close()
		ea.SendRaw(frame)
		ea.SendRaw(frame)
		// Either the connection is still usable or it is closed; a call must
		// finish well within the context in both cases.
		done := make(chan struct{})
		go func() { term.Ping(ctx); close(done) }()
		select {
		case <-done:
		case <-time.After(1500 * time.Millisecond):
			t.Fatalf("call hung after frame %q", frame)
		}
	})
}
