package mt5

import (
	"context"
	"time"
)

// Method names on the wire. Keep in sync with mql5/Experts/GoBridge/GoBridge.mq5
// and docs/protocol.md.
const (
	MethodPing             = "ping"
	MethodTerminalInfo     = "terminal_info"
	MethodAccountInfo      = "account_info"
	MethodSymbolsTotal     = "symbols_total"
	MethodSymbolsGet       = "symbols_get"
	MethodSymbolInfo       = "symbol_info"
	MethodSymbolInfoTick   = "symbol_info_tick"
	MethodSymbolSelect     = "symbol_select"
	MethodCopyRatesFromPos = "copy_rates_from_pos"
	MethodCopyRatesRange   = "copy_rates_range"
	MethodCopyTicksRange   = "copy_ticks_range"
	MethodOrdersGet        = "orders_get"
	MethodPositionsGet     = "positions_get"
	MethodHistoryOrdersGet = "history_orders_get"
	MethodHistoryDealsGet  = "history_deals_get"
	MethodOrderCheck       = "order_check"
	MethodOrderSend        = "order_send"
	MethodSubscribeTicks   = "subscribe_ticks"
	MethodUnsubscribeTicks = "unsubscribe_ticks"
)

// Ping round-trips to the EA and returns the estimated trade-server time
// (TimeTradeServer(), seconds; decode with ServerTime).
func (t *Terminal) Ping(ctx context.Context) (int64, error) {
	var r struct {
		Time int64 `json:"time"`
	}
	err := t.Call(ctx, MethodPing, nil, &r)
	return r.Time, err
}

// TerminalInfo mirrors terminal_info().
func (t *Terminal) TerminalInfo(ctx context.Context) (TerminalInfo, error) {
	var r TerminalInfo
	return r, t.Call(ctx, MethodTerminalInfo, nil, &r)
}

// AccountInfo mirrors account_info().
func (t *Terminal) AccountInfo(ctx context.Context) (AccountInfo, error) {
	var r AccountInfo
	return r, t.Call(ctx, MethodAccountInfo, nil, &r)
}

// SymbolsTotal mirrors symbols_total(). selectedOnly limits to Market Watch.
func (t *Terminal) SymbolsTotal(ctx context.Context, selectedOnly bool) (int, error) {
	var r struct {
		Total int `json:"total"`
	}
	err := t.Call(ctx, MethodSymbolsTotal, map[string]any{"selected": selectedOnly}, &r)
	return r.Total, err
}

// SymbolsGet returns symbol names. Unlike the Python symbols_get() it returns
// names only (use SymbolInfo for details); group uses the same wildcard syntax
// ("*USD*,!EUR*"), empty means all.
func (t *Terminal) SymbolsGet(ctx context.Context, group string, selectedOnly bool) ([]string, error) {
	var r []string
	return r, t.Call(ctx, MethodSymbolsGet, map[string]any{"group": group, "selected": selectedOnly}, &r)
}

// SymbolInfo mirrors symbol_info(symbol).
func (t *Terminal) SymbolInfo(ctx context.Context, symbol string) (SymbolInfo, error) {
	var r SymbolInfo
	return r, t.Call(ctx, MethodSymbolInfo, map[string]any{"symbol": symbol}, &r)
}

// SymbolInfoTick mirrors symbol_info_tick(symbol).
func (t *Terminal) SymbolInfoTick(ctx context.Context, symbol string) (Tick, error) {
	var r Tick
	return r, t.Call(ctx, MethodSymbolInfoTick, map[string]any{"symbol": symbol}, &r)
}

// SymbolSelect mirrors symbol_select(symbol, enable).
func (t *Terminal) SymbolSelect(ctx context.Context, symbol string, enable bool) error {
	return t.Call(ctx, MethodSymbolSelect, map[string]any{"symbol": symbol, "enable": enable}, nil)
}

// CopyRatesFromPos mirrors copy_rates_from_pos: count bars starting start bars
// back from the current one (0 = current bar). Oldest first.
func (t *Terminal) CopyRatesFromPos(ctx context.Context, symbol string, tf Timeframe, start, count int) ([]Rate, error) {
	var r []Rate
	return r, t.Call(ctx, MethodCopyRatesFromPos, map[string]any{
		"symbol": symbol, "timeframe": int(tf), "start": start, "count": count}, &r)
}

// CopyRatesRange mirrors copy_rates_range. from/to are interpreted as MT5
// server time (see ServerTime); their wall-clock reading is sent as-is.
func (t *Terminal) CopyRatesRange(ctx context.Context, symbol string, tf Timeframe, from, to time.Time) ([]Rate, error) {
	var r []Rate
	return r, t.Call(ctx, MethodCopyRatesRange, map[string]any{
		"symbol": symbol, "timeframe": int(tf), "from": wall(from), "to": wall(to)}, &r)
}

// CopyTicksRange mirrors copy_ticks_range. from/to as in CopyRatesRange.
func (t *Terminal) CopyTicksRange(ctx context.Context, symbol string, from, to time.Time, flags CopyTicksFlag) ([]Tick, error) {
	var r []Tick
	return r, t.Call(ctx, MethodCopyTicksRange, map[string]any{
		"symbol": symbol, "from_msc": wallMsc(from), "to_msc": wallMsc(to), "flags": int(flags)}, &r)
}

// Filter narrows orders/positions/history queries. Zero values mean "any".
// Ticket takes precedence over Symbol, as in the Python package.
type Filter struct {
	Symbol string
	Ticket uint64
}

func (f Filter) params() map[string]any {
	return map[string]any{"symbol": f.Symbol, "ticket": f.Ticket}
}

// OrdersGet mirrors orders_get() (active pending orders).
func (t *Terminal) OrdersGet(ctx context.Context, f Filter) ([]TradeOrder, error) {
	var r []TradeOrder
	return r, t.Call(ctx, MethodOrdersGet, f.params(), &r)
}

// PositionsGet mirrors positions_get().
func (t *Terminal) PositionsGet(ctx context.Context, f Filter) ([]TradePosition, error) {
	var r []TradePosition
	return r, t.Call(ctx, MethodPositionsGet, f.params(), &r)
}

func historyParams(from, to time.Time, f Filter) map[string]any {
	p := f.params()
	p["from"] = wall(from)
	p["to"] = wall(to)
	return p
}

// HistoryOrdersGet mirrors history_orders_get(date_from, date_to, ...).
func (t *Terminal) HistoryOrdersGet(ctx context.Context, from, to time.Time, f Filter) ([]TradeOrder, error) {
	var r []TradeOrder
	return r, t.Call(ctx, MethodHistoryOrdersGet, historyParams(from, to, f), &r)
}

// HistoryDealsGet mirrors history_deals_get(date_from, date_to, ...).
func (t *Terminal) HistoryDealsGet(ctx context.Context, from, to time.Time, f Filter) ([]TradeDeal, error) {
	var r []TradeDeal
	return r, t.Call(ctx, MethodHistoryDealsGet, historyParams(from, to, f), &r)
}

// OrderCheck mirrors order_check(request).
func (t *Terminal) OrderCheck(ctx context.Context, req TradeRequest) (OrderCheckResult, error) {
	var r OrderCheckResult
	return r, t.Call(ctx, MethodOrderCheck, req.params(), &r)
}

// OrderSend mirrors order_send(request). As in Python, a rejected trade is not
// a Go error: inspect Retcode (TradeRetcodeDone, TradeRetcodePlaced, ...).
// A Go error means the request never reached the trade server.
func (t *Terminal) OrderSend(ctx context.Context, req TradeRequest) (OrderSendResult, error) {
	var r OrderSendResult
	return r, t.Call(ctx, MethodOrderSend, req.params(), &r)
}

// SubscribeTicks asks the EA to stream ticks for symbol to Ticks().
func (t *Terminal) SubscribeTicks(ctx context.Context, symbol string) error {
	return t.Call(ctx, MethodSubscribeTicks, map[string]any{"symbol": symbol}, nil)
}

// UnsubscribeTicks stops streaming symbol. Empty symbol stops all.
func (t *Terminal) UnsubscribeTicks(ctx context.Context, symbol string) error {
	return t.Call(ctx, MethodUnsubscribeTicks, map[string]any{"symbol": symbol}, nil)
}

// wall sends the wall-clock reading of tm as if it were UTC, matching how MT5
// encodes server time.
func wall(tm time.Time) int64 {
	if tm.IsZero() {
		return 0
	}
	y, mo, d := tm.Date()
	h, mi, s := tm.Clock()
	return time.Date(y, mo, d, h, mi, s, 0, time.UTC).Unix()
}

func wallMsc(tm time.Time) int64 {
	if tm.IsZero() {
		return 0
	}
	return wall(tm)*1000 + int64(tm.Nanosecond()/1e6)
}
