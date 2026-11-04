package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"testing"
)

// FuzzReadFrame: arbitrary bytes never panic, never yield a frame larger than
// the limit or empty, and a frame that is read re-encodes to the same bytes.
func FuzzReadFrame(f *testing.F) {
	f.Add([]byte{0, 0, 0, 2, '{', '}'}, 64)
	f.Add([]byte{0, 0, 0, 0}, 64)
	f.Add([]byte{0xff, 0xff, 0xff, 0xff, 'x'}, 64)
	f.Add([]byte{0, 0, 0, 5, 'a'}, 64)
	f.Add([]byte{0, 0}, 0)
	f.Fuzz(func(t *testing.T, in []byte, max int) {
		if max > 1<<16 || max < -1 {
			max = 1 << 16 // keep allocations bounded; behaviour above is the same
		}
		r := bytes.NewReader(in)
		b, err := ReadFrame(r, max)
		if err != nil {
			if b != nil {
				t.Fatal("data returned with error")
			}
			if len(in) >= 4 && !errors.Is(err, ErrEmptyFrame) && !errors.Is(err, ErrFrameTooLarge) && err != io.ErrUnexpectedEOF {
				t.Fatalf("unexpected error kind %v", err)
			}
			return
		}
		limit := max
		if limit <= 0 {
			limit = DefaultMaxFrame
		}
		if len(b) == 0 || len(b) > limit {
			t.Fatalf("frame of %d bytes accepted (limit %d)", len(b), limit)
		}
		var w bytes.Buffer
		if err := WriteFrame(&w, b); err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(w.Bytes(), in[:4+len(b)]) {
			t.Fatal("re-encoded frame differs from input")
		}
	})
}

// FuzzRequestFlat: whatever scalars are given, the encoded request is one
// flat JSON object holding id, method and every param, with nothing nested
// (the EA's CFlatJson rejects nesting).
func FuzzRequestFlat(f *testing.F) {
	f.Add(uint64(1), "ping", "symbol", "XAUUSD", int64(5), 1.5, true)
	f.Add(uint64(0), "", "", "", int64(-1), math.Inf(1), false)
	f.Add(uint64(math.MaxUint64), "m \"", "id", "\x00", int64(math.MinInt64), -0.0, true)
	f.Fuzz(func(t *testing.T, id uint64, method, key, s string, n int64, x float64, b bool) {
		p := map[string]any{key: s, key + "_n": n, key + "_b": b, key + "_x": x}
		out, err := json.Marshal(Request{ID: id, Method: method, Params: p})
		if err != nil {
			reserved := key == "id" || key == "method" || key+"_n" == "id" || key+"_b" == "id" || key+"_x" == "id"
			if reserved || math.IsNaN(x) || math.IsInf(x, 0) {
				return // reserved names and non-finite floats are refused, by design / by encoding/json
			}
			t.Fatalf("unexpected error: %v", err)
		}
		var m map[string]json.RawMessage
		if err := json.Unmarshal(out, &m); err != nil {
			t.Fatalf("not an object: %s", out)
		}
		for k, v := range m {
			if c := bytes.TrimSpace(v)[0]; c == '{' || c == '[' {
				t.Fatalf("nested value for %q: %s", k, v)
			}
		}
		var hdr struct {
			ID     uint64 `json:"id"`
			Method string `json:"method"`
		}
		json.Unmarshal(out, &hdr)
		if hdr.ID != id || len(m) != len(p)+2 {
			t.Fatalf("id/params lost: %s", out)
		}
		if want, _ := json.Marshal(method); string(m["method"]) != string(want) {
			t.Fatalf("method %s != %s", m["method"], want)
		}
	})
}
