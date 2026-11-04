// Package protocol implements the gomql5 bridge wire format spoken between a
// Go application and the GoBridge MQL5 Expert Advisor.
//
// Every message is one frame: a 4-byte big-endian unsigned length N followed
// by N bytes of UTF-8 JSON (one object). See docs/protocol.md.
package protocol

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// Version is the protocol version announced in the hello message.
const Version = 1

// DefaultMaxFrame is the largest frame accepted by default (32 MiB).
const DefaultMaxFrame = 32 << 20

// ErrFrameTooLarge is returned when a frame's declared length exceeds the limit.
var ErrFrameTooLarge = errors.New("protocol: frame too large")

// ErrEmptyFrame is returned for a zero-length frame.
var ErrEmptyFrame = errors.New("protocol: empty frame")

// WriteFrame writes payload as a single length-prefixed frame.
func WriteFrame(w io.Writer, payload []byte) error {
	if len(payload) == 0 {
		return ErrEmptyFrame
	}
	if uint64(len(payload)) > 0xFFFFFFFF {
		return ErrFrameTooLarge
	}
	buf := make([]byte, 4+len(payload))
	binary.BigEndian.PutUint32(buf, uint32(len(payload)))
	copy(buf[4:], payload)
	_, err := w.Write(buf)
	return err
}

// ReadFrame reads one frame. maxSize <= 0 means DefaultMaxFrame.
// A stream that ends inside a frame yields io.ErrUnexpectedEOF.
func ReadFrame(r io.Reader, maxSize int) ([]byte, error) {
	if maxSize <= 0 {
		maxSize = DefaultMaxFrame
	}
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if n == 0 {
		return nil, ErrEmptyFrame
	}
	if uint64(n) > uint64(maxSize) {
		return nil, fmt.Errorf("%w: %d > %d bytes", ErrFrameTooLarge, n, maxSize)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		if errors.Is(err, io.EOF) {
			err = io.ErrUnexpectedEOF
		}
		return nil, err
	}
	return buf, nil
}

// Message types sent by the EA (field "type").
const (
	TypeHello    = "hello"
	TypeResponse = "res"
	TypeEvent    = "event"
)

// Hello is the first message the EA sends after connecting.
type Hello struct {
	Type      string `json:"type"`
	Proto     int    `json:"proto"`
	Token     string `json:"token"`
	EAVersion string `json:"ea_version"`
	Build     int    `json:"build"`
	Login     int64  `json:"login"`
	Server    string `json:"server"`
	Company   string `json:"company"`
}

// Request is sent by Go to the EA. Params must be scalars (string, bool,
// integer or float): the EA's parser only understands flat objects.
type Request struct {
	ID     uint64
	Method string
	Params map[string]any
}

// MarshalJSON flattens Params next to "id" and "method".
func (r Request) MarshalJSON() ([]byte, error) {
	m := make(map[string]any, len(r.Params)+2)
	for k, v := range r.Params {
		if k == "id" || k == "method" {
			return nil, fmt.Errorf("protocol: reserved param name %q", k)
		}
		switch v.(type) {
		case string, bool, int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64, float32, float64:
		default:
			return nil, fmt.Errorf("protocol: param %q has non-scalar type %T", k, v)
		}
		m[k] = v
	}
	m["id"] = r.ID
	m["method"] = r.Method
	return json.Marshal(m)
}

// Error is the error object carried by a failed response.
type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return fmt.Sprintf("mt5 error %d: %s", e.Code, e.Message) }

// Envelope is the union of all EA→Go messages, decoded once to dispatch.
type Envelope struct {
	Type   string          `json:"type"`
	ID     uint64          `json:"id"`
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result"`
	Error  *Error          `json:"error"`
	Event  string          `json:"event"`
	Data   json.RawMessage `json:"data"`
}

// Bridge-level error codes (negative, matching the Python package's RES_E_*
// where the meaning overlaps). Positive codes are MQL5 GetLastError() values.
const (
	ErrCodeFail          = -1 // generic failure
	ErrCodeInvalidParams = -2 // missing or malformed parameter
	ErrCodeNotFound      = -4 // symbol/ticket not found
	ErrCodeUnsupported   = -7 // unknown method
)
