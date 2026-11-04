package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	msgs := []string{`{"a":1}`, `{"b":"ü"}`}
	for _, m := range msgs {
		if err := WriteFrame(&buf, []byte(m)); err != nil {
			t.Fatal(err)
		}
	}
	for _, want := range msgs {
		got, err := ReadFrame(&buf, 0)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want {
			t.Fatalf("got %q want %q", got, want)
		}
	}
	if _, err := ReadFrame(&buf, 0); !errors.Is(err, io.EOF) {
		t.Fatalf("want io.EOF at clean end, got %v", err)
	}
}

func TestReadFrameTooLarge(t *testing.T) {
	// Declares 1 MiB; limit is 1 KiB. Must be rejected before allocating/reading.
	r := bytes.NewReader([]byte{0x00, 0x10, 0x00, 0x00, '{'})
	if _, err := ReadFrame(r, 1024); !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("want ErrFrameTooLarge, got %v", err)
	}
}

func TestReadFrameTruncated(t *testing.T) {
	// Declares 10 bytes, supplies 3: must not hang, must not return partial data.
	r := bytes.NewReader([]byte{0, 0, 0, 10, '{', '}', ' '})
	if _, err := ReadFrame(r, 0); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("want ErrUnexpectedEOF, got %v", err)
	}
	// Header only, no body: must also be ErrUnexpectedEOF, not a clean io.EOF
	// (callers treat io.EOF as an orderly disconnect).
	r = bytes.NewReader([]byte{0, 0, 0, 10})
	if _, err := ReadFrame(r, 0); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("header-only: want ErrUnexpectedEOF, got %v", err)
	}
}

func TestReadFrameEmpty(t *testing.T) {
	if _, err := ReadFrame(bytes.NewReader([]byte{0, 0, 0, 0}), 0); !errors.Is(err, ErrEmptyFrame) {
		t.Fatalf("want ErrEmptyFrame, got %v", err)
	}
}

func TestRequestMarshalFlat(t *testing.T) {
	b, err := json.Marshal(Request{ID: 7, Method: "symbol_info", Params: map[string]any{"symbol": "EURUSD", "n": 2}})
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	if m["id"].(float64) != 7 || m["method"] != "symbol_info" || m["symbol"] != "EURUSD" || m["n"].(float64) != 2 {
		t.Fatalf("unexpected %s", b)
	}
}

func TestRequestRejectsNested(t *testing.T) {
	if _, err := json.Marshal(Request{ID: 1, Method: "x", Params: map[string]any{"a": []int{1}}}); err == nil {
		t.Fatal("nested param must be rejected")
	}
	if _, err := json.Marshal(Request{ID: 1, Method: "x", Params: map[string]any{"id": 5}}); err == nil {
		t.Fatal("reserved param must be rejected")
	}
}
