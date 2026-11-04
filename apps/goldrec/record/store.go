package record

import (
	"bufio"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// Store is an append-only directory of JSON Lines streams plus a
// content-addressed raw archive:
//
//	<dir>/attempts.jsonl   one line per request to the vendor (or replay read)
//	<dir>/sentiment.jsonl  one line per XAUUSD positioning observation
//	<dir>/prices.jsonl     one line per broker tick
//	<dir>/events.jsonl     run, connection and quality events
//	<dir>/raw/ab/<sha256>.json.gz  outlook response bodies, verbatim
//	<dir>/status.json      health snapshot, rewritten atomically
//
// It is deliberately dumb so it can be swapped for SQLite/Postgres later
// without changing what a record means.
type Store struct {
	dir string
	mu  sync.Mutex
	f   map[string]*stream
}

type stream struct {
	f *os.File
	w *bufio.Writer
}

// Open creates dir if needed.
func Open(dir string) (*Store, error) {
	if err := os.MkdirAll(filepath.Join(dir, "raw"), 0o755); err != nil {
		return nil, err
	}
	return &Store{dir: dir, f: map[string]*stream{}}, nil
}

// Dir is the store directory.
func (s *Store) Dir() string { return s.dir }

func (s *Store) get(name string) (*stream, error) {
	if st, ok := s.f[name]; ok {
		return st, nil
	}
	f, err := os.OpenFile(filepath.Join(s.dir, name+".jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	st := &stream{f: f, w: bufio.NewWriterSize(f, 64<<10)}
	s.f[name] = st
	return st, nil
}

// Append buffers one record. Call Flush (or use AppendSync) to make it durable.
func (s *Store) Append(name string, rec any) error {
	b, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	st, err := s.get(name)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	_, err = st.w.Write(b)
	return err
}

// AppendSync appends and fsyncs that stream before returning.
func (s *Store) AppendSync(name string, rec any) error {
	if err := s.Append(name, rec); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.f[name].sync()
}

func (st *stream) sync() error {
	if err := st.w.Flush(); err != nil {
		return err
	}
	return st.f.Sync()
}

// Flush writes and fsyncs every stream.
func (s *Store) Flush() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var first error
	for _, st := range s.f {
		if err := st.sync(); err != nil && first == nil {
			first = err
		}
	}
	return first
}

// PutRaw stores body under its sha256 (hex) once and returns its relative path.
func (s *Store) PutRaw(sha string, body []byte) (string, error) {
	if len(sha) < 8 {
		return "", fmt.Errorf("record: bad hash %q", sha)
	}
	rel := filepath.Join("raw", sha[:2], sha+".json.gz")
	path := filepath.Join(s.dir, rel)
	if _, err := os.Stat(path); err == nil {
		return rel, nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return "", err
	}
	zw := gzip.NewWriter(tmp)
	_, werr := zw.Write(body)
	cerr := zw.Close()
	serr := tmp.Sync()
	tmp.Close()
	for _, e := range []error{werr, cerr, serr} {
		if e != nil {
			os.Remove(tmp.Name())
			return "", e
		}
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return "", err
	}
	return rel, nil
}

// WriteStatus atomically replaces status.json.
func (s *Store) WriteStatus(v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := filepath.Join(s.dir, ".status.json.tmp")
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(s.dir, "status.json"))
}

// Close flushes and closes every stream.
func (s *Store) Close() error {
	err := s.Flush()
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, st := range s.f {
		st.f.Close()
	}
	s.f = map[string]*stream{}
	return err
}
