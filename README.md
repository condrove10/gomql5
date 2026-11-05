# gomql5

A pure-Go client for **MetaTrader 5**, with an API modelled on the official
[`MetaTrader5`](https://pypi.org/project/MetaTrader5/) Python package. It also
ships a Docker image that runs the MT5 terminal headless under Wine, and one
application built on it: [`goldrec`](#goldrec-gold-positioning-recorder), a
read-only recorder for Myfxbook XAUUSD positioning next to broker gold ticks.

```
┌──────────────── docker: mt5 ─────────────────┐          ┌──── your Go app ────┐
│ Wine ─ terminal64.exe ─ GoBridge.mq5 (EA) ───┼── TCP ──▶│ mt5.Server          │
│        (headless Xvfb, optional VNC)         │  4-byte  │  └─ *mt5.Terminal   │
└──────────────────────────────────────────────┘  len+JSON└─────────────────────┘
```

| | |
|---|---|
| **Library** (`mt5`, `protocol`) | account, symbols, ticks and bars, orders and positions, history, trading, live tick streaming, raw calls |
| **EA** (`mql5/`) | GoBridge Expert Advisor: dials your Go app and serves requests inside the terminal |
| **Image** (`docker/mt5`) | MT5 + Wine + Xvfb; compiles the EA, logs in, allow-lists your host, attaches the EA |
| **Testing kit** | `mt5test.FakeEA` mock, fuzz targets, end-to-end scripts, a one-command verification session (`make session`) |
| **App** (`apps/goldrec`) | Myfxbook XAUUSD long/short positioning + broker gold ticks → append-only JSONL with provenance |

Contents:

1. [Why not port the Python package?](#why-not-port-the-python-package)
2. [Quick start](#quick-start)
3. [Using the package](#using-the-package)
4. [goldrec](#goldrec-gold-positioning-recorder)
5. [Make targets and verification sessions](#make-targets-and-verification-sessions)
6. [Testing](#testing)
7. [Without Docker](#without-docker)
8. [Layout](#layout)

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

## Quick start

### Docker Compose (terminal + example app)

```bash
cp .env.example .env
```

Edit `.env`: set `GOBRIDGE_TOKEN` (`openssl rand -hex 24`) and a **demo**
account (`MT5_LOGIN`, `MT5_PASSWORD`, `MT5_SERVER`), and optionally
`VNC_PASSWORD`.

```bash
docker compose up --build
```

The `app` service runs [`examples/basic`](examples/basic/main.go). It prints
account info, symbol info and the last H1 bars, then streams ticks.

On start, the `mt5` container:

1. Compiles the EA (the log shows `Result: 0 errors, 0 warnings`).
2. Logs in with `MT5_*`.
3. Resolves `app` to an IP.
4. Adds that IP to the terminal's allowed-host list by driving the Options
   dialog with `xdotool`.
5. Checks that the EA connected, and retries if it didn't.

Use `docker stop -t 30` so the terminal can shut down cleanly. Details and
caveats are in [docs/docker.md](docs/docker.md).

> **No account, no live data.** Without `MT5_*` the terminal shows only its
> bundled history and cached quotes (`TerminalInfo.Connected == false`). The
> first "tick" you see is the cached quote, not the market.

### Your own Go app against the container (host networking)

```bash
GOBRIDGE_TOKEN=dev go run ./examples/basic -listen 127.0.0.1:7788 -symbol XAUUSD -ticks 0
```

```bash
docker run --rm --network host --shm-size 512m -e GOBRIDGE_TOKEN=dev -e GOBRIDGE_HOST=127.0.0.1 -e GOBRIDGE_PORT=7788 -e MT5_LOGIN -e MT5_PASSWORD -e MT5_SERVER gomql5/mt5:local
```

Build the image first with `make image` (or `scripts/e2e.sh --build`).

## Using the package

```bash
go get github.com/condrove10/gomql5
```

Every snippet below is taken from a runnable example:
[`mt5/example_test.go`](mt5/example_test.go) and
[`apps/goldrec/myfxbook/example_test.go`](apps/goldrec/myfxbook/example_test.go).
`go test ./...` runs them against the fake EA and checks their output.

### Connect and query

```go
srv, err := mt5.Listen(":7788", mt5.Config{Token: os.Getenv("GOBRIDGE_TOKEN")})
if err != nil { … }
defer srv.Close()

term, err := srv.Accept(ctx)       // blocks until an EA completes the handshake
defer term.Close()
h := term.Hello()                  // h.Login, h.Server, h.Company, h.Build, h.EAVersion

ai, _ := term.AccountInfo(ctx)
fmt.Printf("balance %.2f %s, leverage 1:%d\n", ai.Balance, ai.Currency, ai.Leverage)

tk, _ := term.SymbolInfoTick(ctx, "XAUUSD")
fmt.Println(tk.Bid, tk.Ask, mt5.ServerTimeMsc(tk.TimeMsc))   // broker time

bars, _ := term.CopyRatesFromPos(ctx, "XAUUSD", mt5.TimeframeH1, 0, 100) // oldest first
for _, b := range bars {
    fmt.Println(mt5.ServerTime(b.Time), b.Open, b.High, b.Low, b.Close, b.TickVolume)
}
```

More calls, each with the same arguments as in Python:

```go
ti, _ := term.TerminalInfo(ctx)                           // ti.Connected: logged in to a trade server?
n, _ := term.SymbolsTotal(ctx, false)
names, _ := term.SymbolsGet(ctx, "*XAU*,*GOLD*", false)   // names only; wildcard groups as in MT5
si, _ := term.SymbolInfo(ctx, "XAUUSD")                   // digits, contract size, volume steps, …
_ = term.SymbolSelect(ctx, "XAUUSD", true)                // add to Market Watch

from := time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)      // read as BROKER time (wall clock)
rates, _ := term.CopyRatesRange(ctx, "XAUUSD", mt5.TimeframeM5, from, from.Add(24*time.Hour))
ticks, _ := term.CopyTicksRange(ctx, "XAUUSD", from, from.Add(time.Hour), mt5.CopyTicksAll)

orders, _ := term.OrdersGet(ctx, mt5.Filter{Symbol: "XAUUSD"})    // pending orders
pos, _ := term.PositionsGet(ctx, mt5.Filter{})                    // all open positions
deals, _ := term.HistoryDealsGet(ctx, from, time.Time{}, mt5.Filter{}) // zero "to" = now + 1 day
```

### Stream ticks

```go
if err := term.SubscribeTicks(ctx, "XAUUSD"); err != nil { … }
for {
    select {
    case tk := <-term.Ticks():
        fmt.Printf("%s %.2f/%.2f\n", tk.Symbol, tk.Bid, tk.Ask)
    case <-term.Done():
        log.Println("disconnected:", term.Err())   // see "Reconnects" below
        return
    }
}
```

The EA polls subscribed symbols every `InpTimerMs` (10 ms) and pushes a tick
whenever `time_msc` changes. If you stop reading, ticks beyond
`Config.TickBuffer` (default 4096) are dropped rather than blocking responses.
`term.DroppedTicks()` counts them.

### Reconnects

A reconnecting EA is a **new** `Terminal` from `Accept`, and subscriptions do
not carry over. Loop:

```go
for {
    term, err := srv.Accept(ctx)
    if err != nil { return err }            // ctx done or server closed
    _ = term.SubscribeTicks(ctx, "XAUUSD")  // re-subscribe every time
    serve(ctx, term)                        // until <-term.Done()
    term.Close()
}
```

The heartbeat (`Config.PingInterval`, default 15 s) closes a terminal whose
EA stopped answering, so `Done()` fires even on a silent network drop.

### Trading

```go
res, err := term.OrderSend(ctx, mt5.TradeRequest{
    Action: mt5.TradeActionDeal, Symbol: "EURUSD", Volume: 0.01,
    Type: mt5.OrderTypeBuy, TypeFilling: mt5.OrderFillingIoc, Deviation: 20,
    // Price 0 on a market deal: the EA fills in the current ask/bid.
})
switch {
case err != nil:                           // never reached the trade server
case res.Retcode != mt5.TradeRetcodeDone:  // rejected: res.Retcode, res.Comment
}
chk, _ := term.OrderCheck(ctx, req)        // margin/validity check without sending
```

As in Python, a rejected trade is **not** a Go error. Use a demo account:
`examples/basic -trade` opens and closes a minimum-volume position.

### Errors, timeouts, raw calls

```go
_, err := term.SymbolInfoTick(ctx, "NOPE")
var pe *protocol.Error
if errors.As(err, &pe) && pe.Code == protocol.ErrCodeNotFound { … }   // -4
```

Error codes:

* `-1`: failure
* `-2`: invalid params
* `-4`: not found
* `-7`: unknown method
* Positive codes are MQL5 `GetLastError()` values.

A call without a context deadline gets `Config.RequestTimeout` (30 s).
`errors.Is(err, mt5.ErrClosed)` means the connection is gone.

For a method the EA has but Go has no wrapper for yet:

```go
var out json.RawMessage
err := term.Call(ctx, "some_method", map[string]any{"symbol": "XAUUSD", "n": 5}, &out) // scalar params only
```

### Configuration

| `mt5.Config` field | default | |
|---|---|---|
| `Token` | required | shared secret the EA must present (`InpToken` / `GOBRIDGE_TOKEN`) |
| `AllowNoToken` | false | local testing only |
| `HandshakeTimeout` | 10 s | wait for the EA's hello |
| `RequestTimeout` | 30 s | calls whose context has no deadline |
| `PingInterval` | 15 s | heartbeat; negative disables |
| `TickBuffer` | 4096 | `Ticks()` capacity |
| `MaxFrame` | 32 MiB | largest accepted frame |
| `Logger` | `slog.Default()` | connection logs and EA `log` events |

TLS: `mt5.NewServer(tls.NewListener(ln, cfg), mt5.Config{…})` works on the Go
side today. The EA side is on the [roadmap](docs/ROADMAP.md).

### Times

MT5 timestamps are the **broker server's wall clock**, encoded as if they were
UTC (as in Python). `mt5.ServerTime(sec)` and `mt5.ServerTimeMsc(ms)` decode
them. When you pass a `time.Time`, its wall-clock reading is sent as-is, in
whatever zone it carries. See [docs/protocol.md](docs/protocol.md#time).

### Python mapping

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

Not yet ported:

* `copy_rates_from`, `copy_ticks_from`
* `order_calc_margin`, `order_calc_profit`
* `market_book_*`
* `orders_total`, `positions_total`, `history_*_total`

See [docs/ROADMAP.md](docs/ROADMAP.md).

### Testing your own code without a terminal

`mt5/mt5test.FakeEA` speaks the EA side of the protocol. Give it handlers,
dial your server, and push events:

```go
srv, _ := mt5.Listen("127.0.0.1:0", mt5.Config{Token: "t"})
ea := mt5test.New("t")
ea.Handlers["symbol_info_tick"] = func(p map[string]any) (any, *protocol.Error) {
    if p["symbol"] != "XAUUSD" {
        return nil, &protocol.Error{Code: protocol.ErrCodeNotFound, Message: "not found"}
    }
    return json.RawMessage(`{"bid":4001.1,"ask":4001.4,"time_msc":1762268400123}`), nil
}
ea.Handlers["slow"] = func(map[string]any) (any, *protocol.Error) { return nil, mt5test.NoReply } // test timeouts
ea.Dial(srv.Addr().String())
term, _ := srv.Accept(ctx)

ea.SendEvent("tick", map[string]any{"symbol": "XAUUSD", "bid": 4001.2, "time_msc": 1}) // push a tick
ea.SendRaw([]byte("not json"))   // malformed frame: the terminal must close
reqs := ea.Requests()            // everything your code sent, as flat maps
ea.Close()                       // simulate a disconnect
```

## goldrec: gold positioning recorder

[`apps/goldrec`](apps/goldrec) records **Myfxbook XAUUSD aggregate
positioning** (long/short percentages, lots, position counts, average entry
prices) and, as a separate series, **broker gold ticks** from the EA. It
writes append-only JSON Lines with a content-addressed archive of the raw
responses. It does not trade and contains no order calls. The full
documentation, record formats, limitations and decision register are in
[docs/goldrec.md](docs/goldrec.md).

```bash
make build
```

No vendor access needed (labelled synthetic replay plus broker ticks from an
EA on :7788):

```bash
GOBRIDGE_TOKEN=dev bin/goldrec -source replay -interval 15s
```

Paid API pilot, 60 s:

```bash
MYFXBOOK_EMAIL=… MYFXBOOK_PASSWORD=… GOBRIDGE_TOKEN=… bin/goldrec -source api -entitlement paid -interval 60s -budget 2880 -broker-symbol XAUUSD
```

One authenticated probe (login and one outlook request, then exit):

```bash
MYFXBOOK_EMAIL=… MYFXBOOK_PASSWORD=… bin/goldrec -source api -once -out goldrec-probe
```

Then inspect what was recorded:

```bash
jq -c '{t:.collected_at, L:.supplied.longPercentage, S:.supplied.shortPercentage, lots:[.supplied.longVolume,.supplied.shortVolume], q:.quality}' goldrec-data/sentiment.jsonl
```

```bash
jq -c '{t:.received_at, bid, ask, live:.trade_server_connected}' goldrec-data/prices.jsonl | tail
```

```bash
cat goldrec-data/status.json
```

What it guarantees:

* **Vendor values are kept verbatim.** `"836.10"` stays `"836.10"`. Derived
  shares are computed separately and named as ours.
* **Problems are flagged, never silently fixed.** Missing, null and invalid
  fields are flagged, and those records go to `quarantine.jsonl` instead of
  being zero-filled.
* **Repeats are recorded.** Every successful poll is an observation, even
  when nothing changed, and is marked `same_as_previous`.
* **No invented times.** The API gives no observation time, so
  `provider_time` is `null`.
* **The request budget survives restarts.** It is persisted and fsynced
  before each request.
* **Re-login is throttled**, so a rejected session can't cause a login loop.
* **Secrets never reach logs or the archive.**
* **Cached quotes can't pass as live.** Every price line carries
  `trade_server_connected`.

The parsing layer is usable on its own:

```go
resp, err := myfxbook.Parse(body)              // vendor app errors: resp.Error, resp.Message
n := myfxbook.Normalize(resp.Find("XAUUSD")[0])
fmt.Println(*n.Supplied.LongVolume)            // "836.10"
fmt.Println(*n.Derived.LongVolumeShare)        // 0.62…
fmt.Println(n.Quality, n.Quarantined)          // [total_mismatch] false
```

## Make targets and verification sessions

```bash
make help
```

| target | what it does |
|---|---|
| `make test` | `go vet` + `go test -race` (fast, no log) |
| `make build` | `bin/basic`, `bin/goldrec` |
| `make goldrec` | run the recorder locally (`ARGS=…` to override) |
| `make check` | env + vet + race tests, logged |
| `make fuzz` | every fuzz target for `FUZZTIME` (default 20s) |
| `make image` | build `gomql5/mt5:local` |
| `make probe` | network probes + one Myfxbook API round (if credentials are set) |
| `make e2e` | bridge smoke test against the real terminal |
| `make e2e-goldrec` | recorder pipeline against the real terminal, with a restart (no account needed) |
| `make e2e-live` | recorder with your broker account: passes only when the account (login and server, from the `account` event), the trade-server connection, the window title and fresh ticks all hold (rules L1 to L6 in `docs/TESTING.md`), **within 2 minutes** of the terminal starting (`LIVE_BUDGET`). A named run never skips |
| `make session` | **everything above, in order, into one log** |
| `make session-live` | env, image, probes, e2e-live (account-focused) |
| `make clean`, `make clean-docker` | local outputs; leftover containers and Docker build cache |

### Running a session and handing it back

1. Put credentials in `.env` (git-ignored), or export them. Use the
   account's **read-only (investor) password**: quotes are all that is
   needed, and it can't trade.

   ```
   MT5_LOGIN=<login>
   MT5_PASSWORD=<investor password>
   MT5_SERVER=Broker-Demo
   MT5_SERVERS_DAT=/path/to/servers.dat   # needed when MT5_SERVER is a name
   MYFXBOOK_EMAIL=…        # optional: enables the API probe
   MYFXBOOK_PASSWORD=…
   ```

   The login is config-only: the terminal reads `MT5_LOGIN`, `MT5_PASSWORD`
   and `MT5_SERVER` from its start-up config, and nothing clicks through the
   UI. `MT5_SERVER` has to be one of:

   * **a server name listed in the terminal's `config/servers.dat`.** The
     stock terminal lists only MetaQuotes servers, so a broker name such as
     `FTMO-Demo` falls back to MetaQuotes-Demo ("Invalid account"). Copy
     `servers.dat` from a desktop MT5 that has logged in to the broker once
     (*File → Open Data Folder*, then `config/servers.dat`) and point
     `MT5_SERVERS_DAT` at it.
   * **`address:port`** of the trade server. No `servers.dat` is needed.

   The session keeps the terminal's own copy of `servers.dat` in
   `mt5-state/` (git-ignored). After one successful login, later sessions log
   in from the config alone, even without `MT5_SERVERS_DAT`. If the journal
   shows the fallback to MetaQuotes-Demo, or `authorization on <MT5_SERVER>
   failed`, the live check stops at once and says which of these to fix.

   The live check has a **2-minute budget** (`LIVE_BUDGET=120`): from the
   terminal container's start to the first live tick, once at the start and
   again after the restart. A slower login fails, naming the elapsed time
   and the phase it reached (container started, EA connected, trade server
   connected, first live tick). The phase timings are printed and saved in
   `e2e-live/timings.txt`, e.g. `start: ea_connected=41s trade_server=58s
   first_live_tick=63s (budget 120s)`.

2. Run it. The build takes about 7 GB of disk and network access to
   MetaQuotes.

   ```bash
   make session
   ```

   The live check uses `BTCUSD` by default (`BROKER_SYMBOL`). Crypto trades
   24/7, so the check can't land on a closed market. Pass
   `BROKER_SYMBOL=XAUUSD` for gold during its trading hours.

3. Send back `session-out/<timestamp>.tar.gz`, or just `session.log`.

   * `session.log` has every step's command, output, duration and
     PASS/FAIL/SKIP, then a summary.
   * The bundle adds each step's evidence: terminal journal, compile log,
     screenshots, the recorder's data files, and any fuzz crashers.
   * Secret values are replaced by `[REDACTED]`, and the bundle is scanned
     for leftovers before it is archived.

Behind a TLS-intercepting proxy or Docker Hub rate limits, set
`E2E_CA_CERT`, `HTTPS_PROXY`, `BASE_IMAGE=mirror.gcr.io/library/debian:trixie-slim`
and `GO_IMAGE=mirror.gcr.io/library/golang:1.24-bookworm`.

## Testing

The method is described in [docs/TESTING.md](docs/TESTING.md). Each check is
shown able to fail: inject the bug, watch the test go red, revert.

| layer | where | covers |
|---|---|---|
| Unit + mock | `protocol/`, `mt5/` (`FakeEA`), `apps/goldrec/…` (`httptest` fake vendor) | framing, request flattening, ID multiplexing, timeouts, heartbeat, back-pressure, decoding; **the wire contract of every typed wrapper** (`TestWireContract`: method name + exact params); vendor statuses, session/re-login, budget, redaction; recorder labelling, quarantine, reconnect |
| Runnable examples | `mt5/example_test.go`, `apps/goldrec/myfxbook/example_test.go` | the README's usage, executed with checked output |
| Fuzz | `FuzzReadFrame`, `FuzzRequestFlat` (`protocol`); `FuzzTickRateDecode`, `FuzzServerFrames` (`mt5`); `FuzzParseNormalize`, `FuzzLedgerFile` (`myfxbook`) | no panics or hangs on hostile input, plus invariants: frames within limits round-trip, requests stay flat, supplied values are never invented |
| Shell | `docker/mt5/test/*_test.sh` | container helpers (`/proc` parsing, name resolution, UI lock) |
| End to end | `scripts/e2e.sh`, `scripts/goldrec-e2e.sh` | the real terminal under Wine: compile, allow-list, connect, ticks, reconnect |

Run them:

```bash
go test -race ./...
```

```bash
go test -run '^$' -fuzz '^FuzzParseNormalize$' -fuzztime 60s ./apps/goldrec/myfxbook
```

```bash
make session
```

When a fuzz target fails, Go saves the input under
`<pkg>/testdata/fuzz/<Target>/`. Commit it: plain `go test` then replays it as
a regression test.

To look inside a running terminal (screenshots, journal, Experts log, the
allowed-URL list):

```bash
scripts/mt5ctl.sh status
```

```bash
scripts/mt5ctl.sh goto experts-log
```

```bash
scripts/mt5ctl.sh goto journal
```

## Without Docker

1. Copy `mql5/Experts/GoBridge/` and `mql5/Include/GoBridge/` into your
   terminal's `MQL5` folder and compile `GoBridge.mq5` in MetaEditor.
2. Add your Go host under Tools → Options → Expert Advisors → *Allow
   WebRequest for listed URL*, and enable Algo Trading. Use an **IP address**
   or `localhost`: the terminal silently rejects single-label names like
   `app`.
3. Attach GoBridge to any chart. Set `InpHost`, `InpPort` and `InpToken`.

## Layout

```
protocol/              framing + message types (Go)
mt5/                   Server, Terminal, typed API, generated constants, examples
mt5/mt5test/           fake EA (mock) for tests
mql5/                  GoBridge EA + JSON helper (MQL5)
apps/goldrec/          Myfxbook positioning + gold tick recorder (myfxbook/, record/)
docker/mt5/            Wine + MT5 image, entrypoint, lib.sh (UI helpers), shell tests
scripts/               e2e.sh, goldrec-e2e.sh, session.sh (full verification log), mt5ctl.sh
examples/basic/        demo app (also the compose "app" service)
tools/genconst/        regenerates mt5/constants_gen.go from the Python package
docs/                  protocol, Docker/Linux notes, testing playbook, goldrec, roadmap
Makefile               build, test, fuzz, image, e2e, session targets
```

## License

MIT. The constant values in `mt5/constants_gen.go` are generated from the
MIT-licensed `MetaTrader5` package (© MetaQuotes Ltd.). MetaTrader is a
trademark of MetaQuotes Ltd.; this project isn't affiliated with them.
