// Package myfxbook is a read-only client for the Myfxbook community outlook
// API (aggregate long/short positioning). It keeps the values exactly as the
// vendor supplied them and reports anything unexpected as a quality flag.
//
// Field names come from the vendor's documented example. They have NOT been
// checked against an authenticated response (see docs/goldrec.md).
package myfxbook

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

// Documented symbol fields. Order is the order flags are reported in.
var (
	decimalFields = []string{"longPercentage", "shortPercentage", "longVolume", "shortVolume", "avgLongPrice", "avgShortPrice"}
	countFields   = []string{"longPositions", "shortPositions", "totalPositions"}
	knownFields   = map[string]bool{"name": true}
)

func init() {
	for _, f := range append(append([]string{}, decimalFields...), countFields...) {
		knownFields[f] = true
	}
}

// Response is a decoded outlook (or login) envelope. Application errors are
// separate from transport errors: the vendor answers HTTP 200 with
// {"error":true,"message":"Invalid session."}.
type Response struct {
	Error   bool
	Message string
	Session string            // login.json only
	Symbols []RawSymbol       // get-community-outlook.json only
	General json.RawMessage   // kept verbatim, not interpreted
	Extra   map[string]string // unknown top-level keys -> raw JSON (for diagnosis)
}

// RawSymbol is one element of "symbols", undecoded.
type RawSymbol struct {
	Name   string
	Fields map[string]json.RawMessage
}

// Parse decodes an envelope. It fails only when the body is not a JSON object
// or "error" is missing/not a bool: then the attempt is a parse error and the
// body must be quarantined, never read as data.
func Parse(body []byte) (*Response, error) {
	var top map[string]json.RawMessage
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if err := dec.Decode(&top); err != nil {
		return nil, fmt.Errorf("myfxbook: body is not a JSON object: %w", err)
	}
	if top == nil {
		return nil, fmt.Errorf("myfxbook: body is null")
	}
	r := &Response{Extra: map[string]string{}}
	e, ok := top["error"]
	if !ok {
		return nil, fmt.Errorf("myfxbook: no \"error\" field")
	}
	if err := json.Unmarshal(e, &r.Error); err != nil {
		return nil, fmt.Errorf("myfxbook: \"error\" is not a bool: %s", e)
	}
	for k, v := range top {
		switch k {
		case "error":
		case "message":
			_ = json.Unmarshal(v, &r.Message) // a non-string message is kept in Extra below
			if r.Message == "" && string(v) != `""` && string(v) != "null" {
				r.Extra[k] = string(v)
			}
		case "session":
			if err := json.Unmarshal(v, &r.Session); err != nil {
				return nil, fmt.Errorf("myfxbook: \"session\" is not a string")
			}
		case "general":
			r.General = v
		case "symbols":
			var arr []map[string]json.RawMessage
			if string(v) == "null" {
				continue
			}
			if err := json.Unmarshal(v, &arr); err != nil {
				return nil, fmt.Errorf("myfxbook: \"symbols\" is not an array of objects: %w", err)
			}
			for _, m := range arr {
				var name string
				if n, ok := m["name"]; ok {
					_ = json.Unmarshal(n, &name)
				}
				r.Symbols = append(r.Symbols, RawSymbol{Name: name, Fields: m})
			}
		default:
			r.Extra[k] = string(v)
		}
	}
	return r, nil
}

// Find returns the symbols whose provider name equals name (case-insensitive).
// More than one match is itself a quality problem the caller should flag.
func (r *Response) Find(name string) []RawSymbol {
	var out []RawSymbol
	for _, s := range r.Symbols {
		if strings.EqualFold(s.Name, name) {
			out = append(out, s)
		}
	}
	return out
}

// Values are the supplied numbers as the exact decimal text the vendor sent
// (numeric strings are unquoted). A nil pointer means missing, null or invalid;
// the reason is in the quality flags.
type Values struct {
	LongPercentage  *string `json:"longPercentage"`
	ShortPercentage *string `json:"shortPercentage"`
	LongVolume      *string `json:"longVolume"`
	ShortVolume     *string `json:"shortVolume"`
	LongPositions   *string `json:"longPositions"`
	ShortPositions  *string `json:"shortPositions"`
	TotalPositions  *string `json:"totalPositions"`
	AvgLongPrice    *string `json:"avgLongPrice"`
	AvgShortPrice   *string `json:"avgShortPrice"`
}

func (v *Values) slot(field string) **string {
	switch field {
	case "longPercentage":
		return &v.LongPercentage
	case "shortPercentage":
		return &v.ShortPercentage
	case "longVolume":
		return &v.LongVolume
	case "shortVolume":
		return &v.ShortVolume
	case "longPositions":
		return &v.LongPositions
	case "shortPositions":
		return &v.ShortPositions
	case "totalPositions":
		return &v.TotalPositions
	case "avgLongPrice":
		return &v.AvgLongPrice
	case "avgShortPrice":
		return &v.AvgShortPrice
	}
	return nil
}

// Derived values are computed by us, never by the vendor, and are named so.
// A nil pointer means unavailable (zero denominator or missing input).
type Derived struct {
	LongVolumeShare   *float64 `json:"long_volume_share"`   // longVolume / (longVolume + shortVolume)
	LongCountShare    *float64 `json:"long_count_share"`    // longPositions / (longPositions + shortPositions)
	SumPositions      *int64   `json:"sum_positions"`       // longPositions + shortPositions
	PercentageSum     *float64 `json:"percentage_sum"`      // longPercentage + shortPercentage
	TotalMatchesCount *bool    `json:"total_matches_count"` // totalPositions == SumPositions
}

// Normalized is one symbol after validation.
type Normalized struct {
	ProviderSymbol string   `json:"provider_symbol"`
	Supplied       Values   `json:"supplied"`
	Derived        Derived  `json:"derived"`
	Quality        []string `json:"quality,omitempty"`
	// Quarantined is true when a field needed to interpret the record is
	// missing or invalid. The record is kept (with flags), never zero-filled.
	Quarantined bool `json:"quarantined"`
}

// Normalize validates one symbol. Percentages are allowed to deviate from a
// 100 sum (flagged, not corrected), and totalPositions is never overwritten by
// the computed sum.
func Normalize(s RawSymbol) Normalized {
	n := Normalized{ProviderSymbol: s.Name}
	flag := func(f string, a ...any) { n.Quality = append(n.Quality, fmt.Sprintf(f, a...)) }
	nums := map[string]float64{}

	check := func(field string, integer bool) {
		raw, ok := s.Fields[field]
		if !ok {
			flag("missing:%s", field)
			n.Quarantined = true
			return
		}
		text, isString, err := numberText(raw)
		if err != nil {
			flag("invalid:%s", field)
			n.Quarantined = true
			return
		}
		if text == "" { // JSON null
			flag("null:%s", field)
			n.Quarantined = true
			return
		}
		if isString {
			flag("numeric_string:%s", field)
		}
		f, err := strconv.ParseFloat(text, 64)
		if err != nil || math.IsNaN(f) || math.IsInf(f, 0) || !isDecimalText(text) {
			flag("invalid:%s", field)
			n.Quarantined = true
			return
		}
		if f < 0 {
			flag("negative:%s", field)
		}
		if integer && f != math.Trunc(f) {
			flag("non_integer:%s", field)
		}
		*n.Supplied.slot(field) = &text
		nums[field] = f
	}
	if s.Name == "" {
		flag("missing:name")
		n.Quarantined = true
	}
	for _, f := range decimalFields {
		check(f, false)
	}
	for _, f := range countFields {
		check(f, true)
	}
	var unknown []string
	for k := range s.Fields {
		if !knownFields[k] {
			unknown = append(unknown, k)
		}
	}
	sort.Strings(unknown)
	for _, k := range unknown {
		flag("unknown_field:%s", k)
	}

	lv, okLV := nums["longVolume"]
	sv, okSV := nums["shortVolume"]
	if okLV && okSV {
		if lv+sv > 0 {
			x := lv / (lv + sv)
			n.Derived.LongVolumeShare = &x
		} else {
			flag("zero_denominator:volume")
		}
	}
	lp, okLP := nums["longPositions"]
	sp, okSP := nums["shortPositions"]
	if okLP && okSP {
		if lp+sp > 0 {
			x := lp / (lp + sp)
			n.Derived.LongCountShare = &x
		} else {
			flag("zero_denominator:positions")
		}
		if lp == math.Trunc(lp) && sp == math.Trunc(sp) {
			sum := int64(lp) + int64(sp)
			n.Derived.SumPositions = &sum
			if tp, ok := nums["totalPositions"]; ok {
				m := tp == float64(sum)
				n.Derived.TotalMatchesCount = &m
				if !m {
					flag("total_mismatch")
				}
			}
		}
	}
	lpc, ok1 := nums["longPercentage"]
	spc, ok2 := nums["shortPercentage"]
	if ok1 && ok2 {
		sum := lpc + spc
		n.Derived.PercentageSum = &sum
		if math.Abs(sum-100) > 1.0 {
			flag("percentage_sum_off")
		}
	}
	return n
}

// numberText returns the decimal text of a JSON number or numeric string.
// text=="" with err==nil means null.
func numberText(raw json.RawMessage) (text string, isString bool, err error) {
	t := bytes.TrimSpace(raw)
	switch {
	case string(t) == "null":
		return "", false, nil
	case len(t) > 0 && t[0] == '"':
		var s string
		if err := json.Unmarshal(t, &s); err != nil {
			return "", true, err
		}
		s = strings.TrimSpace(s)
		if s == "" {
			return "", true, fmt.Errorf("empty string")
		}
		return s, true, nil
	case len(t) > 0 && (t[0] == '-' || (t[0] >= '0' && t[0] <= '9')):
		return string(t), false, nil
	}
	return "", false, fmt.Errorf("not a number: %s", t)
}

// isDecimalText rejects forms ParseFloat accepts but JSON/decimal do not
// ("Inf", "0x1p3", "1_000", "+5").
func isDecimalText(s string) bool {
	return json.Valid([]byte(s)) && s[0] != '"'
}
