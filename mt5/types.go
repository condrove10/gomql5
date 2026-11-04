package mt5

import (
	"encoding/json"
	"fmt"
	"time"
)

// Typed enums. Values are generated in constants_gen.go from the official
// MetaTrader5 Python package so they are identical to MQL5's ENUM_* values.
type (
	Timeframe      int
	CopyTicksFlag  int
	TickFlag       uint32
	PositionType   int
	PositionReason int
	OrderType      int
	OrderState     int
	OrderFilling   int
	OrderTypeTime  int
	OrderReason    int
	DealType       int
	DealEntry      int
	DealReason     int
	TradeAction    int
	TradeRetcode   int
	ResultCode     int
)

// ServerTime converts an MT5 datetime (seconds) to time.Time.
//
// MT5 timestamps are in the trade server's time zone, not UTC, but are encoded
// as if they were UTC (the Python package behaves the same way). The returned
// value is therefore in time.UTC with the broker's wall-clock reading; convert
// with the broker's offset if you need true UTC.
func ServerTime(sec int64) time.Time { return time.Unix(sec, 0).UTC() }

// ServerTimeMsc is ServerTime for millisecond timestamps.
func ServerTimeMsc(msc int64) time.Time { return time.UnixMilli(msc).UTC() }

// TerminalInfo mirrors terminal_info().
type TerminalInfo struct {
	Connected      bool    `json:"connected"`
	DLLsAllowed    bool    `json:"dlls_allowed"`
	TradeAllowed   bool    `json:"trade_allowed"`
	EATradeAllowed bool    `json:"ea_trade_allowed"` // MQLInfoInteger(MQL_TRADE_ALLOWED); bridge extra
	Build          int     `json:"build"`
	MaxBars        int     `json:"maxbars"`
	Codepage       int     `json:"codepage"`
	PingLast       int     `json:"ping_last"` // microseconds
	Retransmission float64 `json:"retransmission"`
	Company        string  `json:"company"`
	Name           string  `json:"name"`
	Language       string  `json:"language"`
	Path           string  `json:"path"`
	DataPath       string  `json:"data_path"`
	CommonDataPath string  `json:"commondata_path"`
}

// AccountInfo mirrors account_info().
type AccountInfo struct {
	Login             int64   `json:"login"`
	TradeMode         int     `json:"trade_mode"`
	Leverage          int64   `json:"leverage"`
	LimitOrders       int     `json:"limit_orders"`
	MarginSOMode      int     `json:"margin_so_mode"`
	TradeAllowed      bool    `json:"trade_allowed"`
	TradeExpert       bool    `json:"trade_expert"`
	MarginMode        int     `json:"margin_mode"`
	CurrencyDigits    int     `json:"currency_digits"`
	FIFOClose         bool    `json:"fifo_close"`
	Balance           float64 `json:"balance"`
	Credit            float64 `json:"credit"`
	Profit            float64 `json:"profit"`
	Equity            float64 `json:"equity"`
	Margin            float64 `json:"margin"`
	MarginFree        float64 `json:"margin_free"`
	MarginLevel       float64 `json:"margin_level"`
	MarginSOCall      float64 `json:"margin_so_call"`
	MarginSOSO        float64 `json:"margin_so_so"`
	MarginInitial     float64 `json:"margin_initial"`
	MarginMaintenance float64 `json:"margin_maintenance"`
	Assets            float64 `json:"assets"`
	Liabilities       float64 `json:"liabilities"`
	CommissionBlocked float64 `json:"commission_blocked"`
	Name              string  `json:"name"`
	Server            string  `json:"server"`
	Currency          string  `json:"currency"`
	Company           string  `json:"company"`
}

// SymbolInfo mirrors the commonly used fields of symbol_info().
type SymbolInfo struct {
	Name              string  `json:"name"`
	Description       string  `json:"description"`
	Path              string  `json:"path"`
	CurrencyBase      string  `json:"currency_base"`
	CurrencyProfit    string  `json:"currency_profit"`
	CurrencyMargin    string  `json:"currency_margin"`
	Custom            bool    `json:"custom"`
	Select            bool    `json:"select"`
	Visible           bool    `json:"visible"`
	Digits            int     `json:"digits"`
	Spread            int     `json:"spread"`
	SpreadFloat       bool    `json:"spread_float"`
	TradeMode         int     `json:"trade_mode"`
	TradeCalcMode     int     `json:"trade_calc_mode"`
	TradeExeMode      int     `json:"trade_exemode"`
	FillingMode       int     `json:"filling_mode"` // bit flags: 1=FOK, 2=IOC, 4=BOC
	OrderMode         int     `json:"order_mode"`
	ExpirationMode    int     `json:"expiration_mode"`
	TradeStopsLevel   int     `json:"trade_stops_level"`
	TradeFreezeLevel  int     `json:"trade_freeze_level"`
	SwapMode          int     `json:"swap_mode"`
	SwapRollover3Days int     `json:"swap_rollover3days"`
	Time              int64   `json:"time"`
	Bid               float64 `json:"bid"`
	Ask               float64 `json:"ask"`
	Last              float64 `json:"last"`
	Point             float64 `json:"point"`
	TradeTickValue    float64 `json:"trade_tick_value"`
	TradeTickSize     float64 `json:"trade_tick_size"`
	TradeContractSize float64 `json:"trade_contract_size"`
	VolumeMin         float64 `json:"volume_min"`
	VolumeMax         float64 `json:"volume_max"`
	VolumeStep        float64 `json:"volume_step"`
	VolumeLimit       float64 `json:"volume_limit"`
	SwapLong          float64 `json:"swap_long"`
	SwapShort         float64 `json:"swap_short"`
	MarginInitial     float64 `json:"margin_initial"`
	MarginMaintenance float64 `json:"margin_maintenance"`
}

// Tick mirrors MqlTick. On the wire it is either an object (symbol_info_tick,
// tick events) or a compact array (copy_ticks_*), see docs/protocol.md.
type Tick struct {
	Symbol     string   `json:"symbol,omitempty"` // only set on tick events
	Time       int64    `json:"time"`
	Bid        float64  `json:"bid"`
	Ask        float64  `json:"ask"`
	Last       float64  `json:"last"`
	Volume     uint64   `json:"volume"`
	TimeMsc    int64    `json:"time_msc"`
	Flags      TickFlag `json:"flags"`
	VolumeReal float64  `json:"volume_real"`
}

// UnmarshalJSON accepts the object form and the array form
// [time, bid, ask, last, volume, time_msc, flags, volume_real].
func (t *Tick) UnmarshalJSON(b []byte) error {
	if len(b) > 0 && b[0] == '[' {
		var a []json.Number
		if err := json.Unmarshal(b, &a); err != nil {
			return err
		}
		if len(a) != 8 {
			return fmt.Errorf("mt5: tick array has %d fields, want 8", len(a))
		}
		var err error
		get := func(i int) float64 {
			f, e := a[i].Float64()
			if e != nil && err == nil {
				err = e
			}
			return f
		}
		geti := func(i int) int64 {
			n, e := a[i].Int64()
			if e != nil && err == nil {
				err = e
			}
			return n
		}
		*t = Tick{Time: geti(0), Bid: get(1), Ask: get(2), Last: get(3), Volume: uint64(geti(4)),
			TimeMsc: geti(5), Flags: TickFlag(geti(6)), VolumeReal: get(7)}
		return err
	}
	type plain Tick
	return json.Unmarshal(b, (*plain)(t))
}

// Rate mirrors MqlRates. Wire form is the array
// [time, open, high, low, close, tick_volume, spread, real_volume].
type Rate struct {
	Time       int64
	Open       float64
	High       float64
	Low        float64
	Close      float64
	TickVolume int64
	Spread     int
	RealVolume int64
}

// UnmarshalJSON decodes the compact array form.
func (r *Rate) UnmarshalJSON(b []byte) error {
	var a []json.Number
	if err := json.Unmarshal(b, &a); err != nil {
		return err
	}
	if len(a) != 8 {
		return fmt.Errorf("mt5: rate array has %d fields, want 8", len(a))
	}
	var err error
	f := func(i int) float64 {
		v, e := a[i].Float64()
		if e != nil && err == nil {
			err = e
		}
		return v
	}
	n := func(i int) int64 {
		v, e := a[i].Int64()
		if e != nil && err == nil {
			err = e
		}
		return v
	}
	*r = Rate{Time: n(0), Open: f(1), High: f(2), Low: f(3), Close: f(4), TickVolume: n(5), Spread: int(n(6)), RealVolume: n(7)}
	return err
}

// TradeOrder mirrors orders_get() / history_orders_get() entries.
type TradeOrder struct {
	Ticket         uint64        `json:"ticket"`
	TimeSetup      int64         `json:"time_setup"`
	TimeSetupMsc   int64         `json:"time_setup_msc"`
	TimeDone       int64         `json:"time_done"`
	TimeDoneMsc    int64         `json:"time_done_msc"`
	TimeExpiration int64         `json:"time_expiration"`
	Type           OrderType     `json:"type"`
	TypeTime       OrderTypeTime `json:"type_time"`
	TypeFilling    OrderFilling  `json:"type_filling"`
	State          OrderState    `json:"state"`
	Magic          int64         `json:"magic"`
	PositionID     uint64        `json:"position_id"`
	PositionByID   uint64        `json:"position_by_id"`
	Reason         OrderReason   `json:"reason"`
	VolumeInitial  float64       `json:"volume_initial"`
	VolumeCurrent  float64       `json:"volume_current"`
	PriceOpen      float64       `json:"price_open"`
	SL             float64       `json:"sl"`
	TP             float64       `json:"tp"`
	PriceCurrent   float64       `json:"price_current"`
	PriceStopLimit float64       `json:"price_stoplimit"`
	Symbol         string        `json:"symbol"`
	Comment        string        `json:"comment"`
	ExternalID     string        `json:"external_id"`
}

// TradePosition mirrors positions_get() entries.
type TradePosition struct {
	Ticket        uint64         `json:"ticket"`
	Time          int64          `json:"time"`
	TimeMsc       int64          `json:"time_msc"`
	TimeUpdate    int64          `json:"time_update"`
	TimeUpdateMsc int64          `json:"time_update_msc"`
	Type          PositionType   `json:"type"`
	Magic         int64          `json:"magic"`
	Identifier    uint64         `json:"identifier"`
	Reason        PositionReason `json:"reason"`
	Volume        float64        `json:"volume"`
	PriceOpen     float64        `json:"price_open"`
	SL            float64        `json:"sl"`
	TP            float64        `json:"tp"`
	PriceCurrent  float64        `json:"price_current"`
	Swap          float64        `json:"swap"`
	Profit        float64        `json:"profit"`
	Symbol        string         `json:"symbol"`
	Comment       string         `json:"comment"`
	ExternalID    string         `json:"external_id"`
}

// TradeDeal mirrors history_deals_get() entries.
type TradeDeal struct {
	Ticket     uint64     `json:"ticket"`
	Order      uint64     `json:"order"`
	Time       int64      `json:"time"`
	TimeMsc    int64      `json:"time_msc"`
	Type       DealType   `json:"type"`
	Entry      DealEntry  `json:"entry"`
	Magic      int64      `json:"magic"`
	PositionID uint64     `json:"position_id"`
	Reason     DealReason `json:"reason"`
	Volume     float64    `json:"volume"`
	Price      float64    `json:"price"`
	Commission float64    `json:"commission"`
	Swap       float64    `json:"swap"`
	Profit     float64    `json:"profit"`
	Fee        float64    `json:"fee"`
	Symbol     string     `json:"symbol"`
	Comment    string     `json:"comment"`
	ExternalID string     `json:"external_id"`
}

// TradeRequest mirrors MqlTradeRequest (the dict passed to order_send()).
type TradeRequest struct {
	Action      TradeAction
	Magic       uint64
	Order       uint64
	Symbol      string
	Volume      float64
	Price       float64
	StopLimit   float64
	SL          float64
	TP          float64
	Deviation   uint64
	Type        OrderType
	TypeFilling OrderFilling
	TypeTime    OrderTypeTime
	Expiration  int64 // MT5 server-time seconds
	Comment     string
	Position    uint64
	PositionBy  uint64
}

func (r TradeRequest) params() map[string]any {
	return map[string]any{
		"action": int(r.Action), "magic": r.Magic, "order": r.Order, "symbol": r.Symbol,
		"volume": r.Volume, "price": r.Price, "stoplimit": r.StopLimit, "sl": r.SL, "tp": r.TP,
		"deviation": r.Deviation, "type": int(r.Type), "type_filling": int(r.TypeFilling),
		"type_time": int(r.TypeTime), "expiration": r.Expiration, "comment": r.Comment,
		"position": r.Position, "position_by": r.PositionBy,
	}
}

// OrderSendResult mirrors MqlTradeResult.
type OrderSendResult struct {
	Retcode         TradeRetcode `json:"retcode"`
	Deal            uint64       `json:"deal"`
	Order           uint64       `json:"order"`
	Volume          float64      `json:"volume"`
	Price           float64      `json:"price"`
	Bid             float64      `json:"bid"`
	Ask             float64      `json:"ask"`
	Comment         string       `json:"comment"`
	RequestID       uint32       `json:"request_id"`
	RetcodeExternal int          `json:"retcode_external"`
}

// OrderCheckResult mirrors MqlTradeCheckResult.
type OrderCheckResult struct {
	Retcode     TradeRetcode `json:"retcode"`
	Balance     float64      `json:"balance"`
	Equity      float64      `json:"equity"`
	Profit      float64      `json:"profit"`
	Margin      float64      `json:"margin"`
	MarginFree  float64      `json:"margin_free"`
	MarginLevel float64      `json:"margin_level"`
	Comment     string       `json:"comment"`
}
