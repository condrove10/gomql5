# gomql5

A pure-Go client for **MetaTrader 5**, with an API modelled on the official
[`MetaTrader5`](https://pypi.org/project/MetaTrader5/) Python package. It also
ships a Docker image that runs the MT5 terminal headless under Wine.

```
┌──────────────── docker: mt5 ─────────────────┐          ┌──── your Go app ────┐
│ Wine ─ terminal64.exe ─ GoBridge.mq5 (EA) ───┼── TCP ──▶│ mt5.Server          │
│        (headless Xvfb, optional VNC)         │  4-byte  │  └─ *mt5.Terminal   │
└──────────────────────────────────────────────┘  len+JSON└─────────────────────┘
```

## Why not port the Python package?

The `MetaTrader5` wheel only runs on Windows. It's a thin wrapper around a
compiled module that talks to `terminal64.exe` over an **undocumented named
pipe** (`\\.\pipe\MT5.Terminal.<hash>`). A Go port would mean
reverse-engineering that private protocol, and it would still be tied to
Windows.

Instead, a small open-source MQL5 Expert Advisor runs inside the terminal and
connects out to your Go program over TCP. The protocol is ours and documented
([docs/protocol.md](docs/protocol.md)). MQL5 sockets can only connect, never
listen, so the Go side is the server. For how MT5 runs on Linux/Docker in
2026, see [docs/docker.md](docs/docker.md).

## Quick start (Docker)

```bash
cp .env.example .env
```

Then edit `.env`: set `GOBRIDGE_TOKEN` and a demo account, and optionally
`VNC_PASSWORD`.

```bash
docker compose up --build
```

The `app` service runs [`examples/basic`](examples/basic/main.go). It prints
account info, symbol info and the last H1 bars, then streams ticks.

On start, the `mt5` container:

1. Compiles the EA.
2. Resolves `app` to an IP.
3. Adds that IP to the terminal's allowed-host list by driving the Options
   dialog with `xdotool`.
4. Checks that the EA connected, and retries if it didn't.

Use `docker stop -t 30` so the terminal can shut down cleanly. Details and
caveats are in [docs/docker.md](docs/docker.md).

## Using the package

```go
srv, _ := mt5.Listen(":7788", mt5.Config{Token: os.Getenv("GOBRIDGE_TOKEN")})
term, _ := srv.Accept(ctx)                 // one EA = one terminal/account

ai, _ := term.AccountInfo(ctx)
rates, _ := term.CopyRatesRange(ctx, "EURUSD", mt5.TimeframeH1, from, to)
res, _ := term.OrderSend(ctx, mt5.TradeRequest{
    Action: mt5.TradeActionDeal, Symbol: "EURUSD", Volume: 0.01,
    Type: mt5.OrderTypeBuy, TypeFilling: mt5.OrderFillingIoc, Deviation: 20,
})
if res.Retcode != mt5.TradeRetcodeDone { /* rejected by the trade server */ }

_ = term.SubscribeTicks(ctx, "EURUSD")
for tk := range term.Ticks() { … }
```

| Python `MetaTrader5` | gomql5 |
|---|---|
| `initialize()` / `login()` | the EA connects to `Server.Accept`; login is set in the terminal or container env |
| `terminal_info()`, `account_info()` | `TerminalInfo`, `AccountInfo` |
| `symbols_total/get`, `symbol_info`, `symbol_info_tick`, `symbol_select` | same names in CamelCase (`SymbolsGet` returns names only) |
| `copy_rates_from_pos`, `copy_rates_range`, `copy_ticks_range` | `CopyRatesFromPos`, `CopyRatesRange`, `CopyTicksRange` |
| `orders_get`, `positions_get`, `history_orders_get`, `history_deals_get` | same names, with a `Filter{Symbol, Ticket}` |
| `order_check`, `order_send` | `OrderCheck`, `OrderSend` |
| (none) | `SubscribeTicks` + `Ticks()` channel |
| `mt5.TIMEFRAME_H1`, `mt5.TRADE_RETCODE_DONE`, … | `mt5.TimeframeH1`, `mt5.TradeRetcodeDone`, … (generated from the Python package) |

Not yet ported: `copy_rates_from`, `copy_ticks_from`, `order_calc_margin`,
`order_calc_profit`, `market_book_*`, `orders_total`, `positions_total`,
`history_*_total`. See [docs/ROADMAP.md](docs/ROADMAP.md).

**Times:** MT5 timestamps are in broker server time. Use `mt5.ServerTime` to
decode them; see [docs/protocol.md](docs/protocol.md#time).

## Without Docker

1. Copy `mql5/Experts/GoBridge/` and `mql5/Include/GoBridge/` into your
   terminal's `MQL5` folder and compile `GoBridge.mq5` in MetaEditor.
2. Add your Go host under Tools → Options → Expert Advisors → *Allow
   WebRequest for listed URL*, and enable Algo Trading. Use an **IP address**
   or `localhost`: the terminal silently rejects single-label names like
   `app`.
3. Attach GoBridge to any chart. Set `InpHost`, `InpPort` and `InpToken`.

## Testing

See [docs/TESTING.md](docs/TESTING.md). In short:

```bash
go test -race ./...
```

```bash
scripts/e2e.sh --build
```

```bash
scripts/mt5ctl.sh goto experts-log
```

### Without a terminal

`mt5/mt5test.FakeEA` speaks the EA side of the protocol:

```go
ea := mt5test.New(token)
ea.Handlers["account_info"] = func(map[string]any) (any, *protocol.Error) { return myInfo, nil }
ea.Dial(srv.Addr().String())
```

## Layout

```
protocol/              framing + message types (Go)
mt5/                   Server, Terminal, typed API, generated constants
mt5/mt5test/           fake EA for tests
mql5/                  GoBridge EA + JSON helper (MQL5)
docker/mt5/            Wine + MT5 image, entrypoint, lib.sh (UI helpers), shell tests
scripts/               e2e.sh (end-to-end smoke test), mt5ctl.sh (look inside the terminal)
examples/basic/        demo app (also the compose "app" service)
tools/genconst/        regenerates mt5/constants_gen.go from the Python package
docs/                  protocol, Docker/Linux notes, roadmap
```

## License

MIT. The constant values in `mt5/constants_gen.go` are generated from the
MIT-licensed `MetaTrader5` package (© MetaQuotes Ltd.). MetaTrader is a
trademark of MetaQuotes Ltd.; this project isn't affiliated with them.
