# Roadmap and session handoff

This project will be built over several sessions. Each session should:

1. Read this file and `CLAUDE.md`.
2. Pick the next open item.
3. Update the **Status** column before finishing, recording what was verified
   and how.

## Status (end of session 1, 2026-11-04)

| area | state | how it was verified |
|---|---|---|
| Wire protocol (`protocol/`) | done | unit tests; injected bugs (size limit, truncation) shown to be caught |
| Go server/terminal (`mt5/server.go`) | done | `go test -race`; injected bugs (token check, ID matching, pending-on-disconnect, tick back-pressure, heartbeat) shown to be caught |
| Typed API (`mt5/api.go`, `types.go`) | done for v1 scope | FakeEA tests for decoding (array rates/ticks, account, order send), wall-clock time encoding |
| Constants (`constants_gen.go`) | generated from MetaTrader5 5.0.6231 | spot-check test against MQL5 enum values |
| GoBridge EA (`mql5/`) | done for v1 scope | **compiled with MetaEditor (build 6295) under Wine: 0 errors, 0 warnings**; ran in the terminal; ping/terminal_info/account_info/symbol_info/copy_rates_from_pos/subscribe_ticks + tick events exercised end to end by `examples/basic` |
| Docker image (`docker/mt5`) | done | built and run in the sandbox: host-network mode (IP and `localhost`) and `docker compose` (service name `app`), fresh and reused volumes; `bridge_connected` helper has a shell test (`docker/mt5/test`) shown to catch the IPv6-less `/proc` bug |
| Broker login, trading | **not verified** | no account was available. `order_check`/`order_send`/`positions_get`/`history_*`/`copy_ticks_range` have only been tested against FakeEA |

Session 2 added the verification tooling:

* `docs/TESTING.md` (playbook)
* `scripts/e2e.sh` (one-command end-to-end with evidence)
* `scripts/mt5ctl.sh` (screenshots, walkthrough, logs)
* `docker/mt5/lib.sh` (single source of UI coordinates, plus a UI lock)
* shell tests under `docker/mt5/test`

Session 3 (2026-11-04) added `apps/goldrec` (see `docs/goldrec.md`):

| area | state | how it was verified |
|---|---|---|
| Myfxbook API adapter (`apps/goldrec/myfxbook`) | done, **not run against an authenticated account** | httptest fake vendor + captured real unauthenticated error bodies; 16 injected bugs caught |
| Recorder (`apps/goldrec/record`, `main.go`) | done for JSONL storage | FakeEA tests; `scripts/goldrec-e2e.sh --broker-symbol EURUSD --min-ticks 1 --restart` PASS against the real terminal |
| Live gold ticks | **not verified** | the terminal has no account: XAUUSD has no quote or history (`CopyRates` 4401). The `e2e.sh` "tick" is the cached EURUSD quote (`time_msc` 2024-08-23), not live data |

Session 4 (2026-11-04):

* **Live gold attempt.** The FTMO demo account (read-only password) couldn't
  connect from the cloud sandbox (see `docs/TESTING.md` §2a).
* **Tests.** Added a wire-contract test for every wrapper, event-path tests,
  runnable examples, and six fuzz targets. The new checks were shown able to
  fail: 7 injected bugs, all caught after strengthening two checks.
* **Tooling.** Added `Makefile` + `scripts/session.sh` (one-log verification
  sessions) and `mt5ctl find-broker`.

## Open items, in priority order

0. **goldrec go-live** (needs credentials and a network that reaches the
   broker; run `make session-live FIND_BROKER=…` and review the bundle): `goldrec -source api -once`
   with Myfxbook credentials; check the field names and the session format;
   then `goldrec-e2e.sh --source api --restart` with a demo account
   (`MT5_*`), expecting `trade_server_connected:true`. Make `e2e.sh` require
   a fresh tick once an account is available.

1. **Demo account end to end.** Set `MT5_LOGIN`/`MT5_PASSWORD`/`MT5_SERVER`
   (demo), run `docker compose up`, then run `examples/basic -trade`. Check
   and record:
   * the login appears in the hello
   * the `copy_ticks_range` and history row counts match the terminal
   * `order_send` open/close retcodes
2. **Allow-list robustness.** (Tooling to investigate it is in place:
   `scripts/mt5ctl.sh goto allowlist`, and `docs/TESTING.md`.)
   * `allow-host.sh` drives the UI by screen coordinates. If MetaQuotes moves
     the dialog it breaks; the entrypoint then logs "giving up" after 10
     attempts.
   * Ideas: find why the list doesn't persist across restarts (it is
     written encrypted to `config/settings.ini` on a clean exit, yet came back
     empty), or test whether the built-in MCP server (below) avoids the need
     for sockets.
3. **TLS.**
   * Go: `mt5.NewServer(tls.NewListener(ln, cfg), …)` already works.
   * EA: add `InpTLS`. After `SocketConnect`, call
     `SocketTlsHandshake(sock, host)` and switch to
     `SocketTlsSend`/`SocketTlsRead(Available)`.
   * Add a cert-pinning or CA option.
   * Docker: mount the certificates.
   * Test: a Go-only TLS test with FakeEA (FakeEA needs a TLS dial option).
4. **Reconnect helper in Go.** Today a reconnecting EA is a *new* `Terminal`
   from `Accept`. Add an optional `Session` wrapper that keys on login,
   re-subscribes ticks and lets callers wait for reconnection.
5. **Remaining Python API:**
   * `copy_rates_from`, `copy_ticks_from`
   * `order_calc_margin`, `order_calc_profit`
   * `orders_total`, `positions_total`, `history_*_total`
   * `market_book_add/get/release` (needs `OnBookEvent`, sent as events)
   * `history_*_get(position=)`
6. **Trade events.** Push `OnTradeTransaction` as `event:"trade"` so Go
   doesn't have to poll positions.
7. **Performance.**
   * Measure `copy_ticks_range` with 200k rows (JSON building in MQL5).
   * Consider a binary row format for bars and ticks if it's too slow.
8. **Image hardening.**
   * Pin the Wine version.
   * Run as non-root (currently root inside the container).
   * Optionally install WebView2.
   * Push to GHCR from CI. Building it needs ~7.3 GB and network access to
     MetaQuotes.
9. **Explore the terminal's built-in MCP server.** Builds from 2026 start an
   MCP endpoint (`http://127.0.0.1:22346/mcp`, API key in
   `config/assistant.ini`). Document what tools it exposes. It might replace
   or complement the EA for some calls.
10. **Multi-account.** One container per account works now. Document a
   compose example with N terminals and one Go server (`Hello().Login`
   identifies each).

## Decisions already made (don't revisit without cause)

* Our own EA plus TCP, not a reverse-engineered pipe and not a Python sidecar.
* Go is the TCP server; the EA dials out (forced by MQL5).
* Plain TCP now; TLS is designed in (`NewServer` takes any `net.Listener`).
* Requests are flat JSON, so the MQL5 parser stays small. Responses can nest.
* Licence: MIT.
