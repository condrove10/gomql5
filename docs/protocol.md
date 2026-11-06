# gomql5 bridge protocol, version 1

The protocol between a Go application (`mt5.Server`) and the GoBridge EA
(`mql5/Experts/GoBridge/GoBridge.mq5`).

## Transport

* TCP. **The EA connects to Go.** MQL5's `Socket*` functions can only connect
  (`SocketCreate`/`SocketConnect`); there is no listen or accept.
* The terminal only allows connections to hosts in *Tools → Options → Expert
  Advisors → Allow WebRequest for listed URL*. A program cannot add hosts to
  that list itself.
* TLS (planned): the Go side wraps its listener with `tls.NewListener` and the
  EA calls `SocketTlsHandshake` after connecting. The framing doesn't change.

## Framing

```
+----------------+-------------------------------+
| uint32 BE  N   | N bytes UTF-8 JSON (1 object) |
+----------------+-------------------------------+
```

* `N` must be between 1 and 32 MiB (`protocol.DefaultMaxFrame`, `MAX_FRAME`
  in the EA). Either side drops the connection on a bad length.
* A stream that ends inside a frame is an error (`io.ErrUnexpectedEOF`), not
  a clean disconnect.

## Handshake

The EA's first frame is:

```json
{"type":"hello","proto":1,"token":"…","ea_version":"0.1.0",
 "build":5000,"login":12345678,"server":"Broker-Demo","company":"Broker Ltd"}
```

Go checks `proto == 1` and compares `token` in constant time. If either check
fails, Go closes the connection without replying. There is no ack: once the
hello is accepted, Go simply starts sending requests. The EA retries the
connection every `InpReconnectMs`.

## Requests (Go → EA)

A request is a **flat** JSON object: `id` (uint64, unique per connection),
`method` (string), and the parameters as scalar siblings. The EA's parser
(`CFlatJson`) rejects nested objects and arrays, and the Go encoder refuses
to produce them.

```json
{"id":7,"method":"copy_rates_range","symbol":"EURUSD","timeframe":16385,"from":1767225600,"to":1767312000}
```

## Responses (EA → Go)

```json
{"type":"res","id":7,"ok":true,"result":<any JSON>}
{"type":"res","id":7,"ok":false,"error":{"code":-4,"message":"symbol 'XYZ' not found"}}
```

Error codes:

* **Negative codes** come from the bridge itself. They reuse the Python
  package's `RES_E_*` values where the meaning is the same:
  * `-1`: failure
  * `-2`: invalid params
  * `-4`: not found
  * `-7`: unknown method
* **Positive codes** are MQL5 `GetLastError()` values.

A trade the server rejects is **not** an error. `order_send` returns
`ok:true` with the trade server's `retcode`, as Python does.

## Events (EA → Go, unsolicited)

```json
{"type":"event","event":"tick","data":{"symbol":"EURUSD","time":…,"bid":…,"ask":…,"last":…,"volume":…,"time_msc":…,"flags":6,"volume_real":…}}
```

The EA polls `SymbolInfoTick` for every subscribed symbol on each timer tick
(`InpTimerMs`, default 10 ms) and in `OnTick`. It sends an event when
`time_msc` changes. The EA sends only the latest quote per poll, so ticks
between polls and during a disconnect are not delivered and nothing counts
them; `DroppedTicks` counts only Go-side overflow. A consumer that needs every
tick should use `CopyTicksRange` from the last stored `time_msc` as the
record, on reconnect and periodically. Subscriptions are cleared on
disconnect, so **Go must re-subscribe after a reconnect**.

## Time

All `time*` fields and parameters are MT5 datetimes: seconds (or ms for
`*_msc`) in the **broker's server time zone**, encoded as if they were UTC.
This matches the Python package. `mt5.ServerTime` decodes them. When Go
sends a `time.Time`, it sends that time's wall-clock reading in whatever
zone it carries.

## Methods

| method | params | result |
|---|---|---|
| `ping` | – | `{"time": TimeTradeServer()}` |
| `terminal_info` | – | object (see `mt5.TerminalInfo`) |
| `account_info` | – | object (`mt5.AccountInfo`) |
| `symbols_total` | `selected` bool | `{"total": n}` |
| `symbols_get` | `group` string (`"*USD*,!EUR*"`), `selected` bool | `["EURUSD", …]` |
| `symbol_info` | `symbol` | object (`mt5.SymbolInfo`) |
| `symbol_info_tick` | `symbol` | tick object |
| `symbol_select` | `symbol`, `enable` bool | `true` |
| `copy_rates_from_pos` | `symbol`, `timeframe`, `start`, `count` | `[[time,open,high,low,close,tick_volume,spread,real_volume], …]` oldest first |
| `copy_rates_range` | `symbol`, `timeframe`, `from`, `to` | same |
| `copy_ticks_range` | `symbol`, `from_msc`, `to_msc`, `flags` | `[[time,bid,ask,last,volume,time_msc,flags,volume_real], …]` |
| `orders_get` | `symbol`, `ticket` (0 = any) | `[order, …]` |
| `positions_get` | `symbol`, `ticket` | `[position, …]` |
| `history_orders_get` | `from`, `to` (0 = now+1 day), `symbol`, `ticket` (a ticket ignores the dates) | `[order, …]` |
| `history_deals_get` | same | `[deal, …]` |
| `order_check` | MqlTradeRequest fields: `action`, `magic`, `order`, `symbol`, `volume`, `price`, `stoplimit`, `sl`, `tp`, `deviation`, `type`, `type_filling`, `type_time`, `expiration`, `comment`, `position`, `position_by` | MqlTradeCheckResult object |
| `order_send` | same as `order_check` (if a `TRADE_ACTION_DEAL` has `price` 0, the EA fills in ask or bid) | MqlTradeResult object |
| `subscribe_ticks` | `symbol` | `true` |
| `unsubscribe_ticks` | `symbol` (empty = all) | `true` |

Bars and ticks are sent as arrays to keep responses small. A response holds at
most `InpMaxItems` rows (default 200000); for larger ranges the EA returns
`-2`, and you should split the range.

## Adding a method

1. EA: add a branch to `Dispatch()` and an `M_*` function in `GoBridge.mq5`.
2. Go: add a `Method*` constant and a typed wrapper in `mt5/api.go`.
   `Terminal.Call` works immediately, even before the wrapper exists.
3. Add a test in `mt5/mt5_test.go` using `mt5test.FakeEA`.
4. Document it in the table above. Bump `protocol.Version` only for
   incompatible changes.
