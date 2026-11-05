# Testing and verification playbook

How work on gomql5 is checked, and how to investigate when it isn't working.
Every command quoted here was run in sessions 1–2 (2026-11-04) against MT5 build
6295 on Wine 11.21.

## 1. Principles

1. **Each layer gets its own check, and each check is shown able to fail.**
   Inject the bug, watch the check go red, revert, watch it go green. A check
   you haven't seen fail isn't evidence.
2. **The real terminal is the final judge.** Unit tests and the FakeEA prove the
   Go side matches *our* model of MT5. Only the container proves MT5 agrees. Any
   change to the EA, the Docker image, or assumptions about MT5 behaviour ends with
   `scripts/e2e.sh` passing.
3. **Look, don't guess.** The terminal is a GUI with no window manager. When
   something doesn't happen, take a screenshot (`scripts/mt5ctl.sh`) before
   forming a theory. Most session-1/2 bugs were obvious on screen and invisible
   in logs.
4. **Quote evidence; label the rest.** Reports cite actual output (PASS line,
   compile `Result:`, screenshot path). Anything not run here (broker login,
   trading) is written down as *unverified* with the steps that would settle it.
5. **Every fixed bug leaves a regression test** at the cheapest layer that can
   catch it (Go test > shell test > e2e).

## 2. Verification layers

| layer | command | catches | cost |
|---|---|---|---|
| Go unit + FakeEA | `go vet ./... && go test -race -count=1 ./...` | framing, multiplexing, timeouts, decoding, params; `TestWireContract` pins method + params of every wrapper; runnable `Example*` functions | seconds |
| Go fuzz | `make fuzz` (or `go test -run '^$' -fuzz '^FuzzX$' -fuzztime 60s ./pkg`) | panics/hangs on hostile frames, request flattening, tick/rate decoding, vendor bodies, ledger files | 20 s per target |
| Container shell helpers | `for t in docker/mt5/test/*_test.sh; do bash "$t"; done` | entrypoint/lib logic (`/proc` parsing, name resolution, UI lock) | seconds |
| MQL5 compile | runs inside every container start; `scripts/mt5ctl.sh logs compile` | MQL5 syntax/API errors (e.g. `TERMINAL_TRADEAPI_DISABLED` doesn't exist in MQL5) | in e2e |
| End to end | `scripts/e2e.sh [--build] [--compose]` | everything between Go and the real terminal | 1–2 min (+~6 min build) |
| Visual walkthrough | `scripts/mt5ctl.sh goto …` / `shot` | UI state, dialogs, EA log lines that never reach disk | seconds per screen |
| Broker / trading | `examples/basic -trade` on a demo account | real trade-server behaviour | **not run yet** |

Proving a check can fail: examples from sessions 1–2, each with a matching test.

| check | how it was made to fail |
|---|---|
| `protocol` tests | perl substitutions disabling the size limit, truncation handling, … |
| `docker/mt5/test/bridge_connected_test.sh` | old awk line that read a missing `/proc/net/tcp6` |
| `docker/mt5/test/resolve_host_test.sh` | dropping `\|\| true` after `getent` |
| `docker/mt5/test/ui_lock_test.sh` | replacing `flock` with `:` (output: `A1 B1 A2 …`) |
| `scripts/e2e.sh` | `--app-token` mismatch → `FAIL: … bad token`; `UI_OPTIONS_OK="10 10"` → `FAIL: no tick within 180s` |

## 2a. One-command sessions (`make session`)

`scripts/session.sh` (behind every `make` verification target) runs the
layers in order and writes `session-out/<ts>/session.log`: each step's
command, output, duration and PASS/FAIL/SKIP, then a summary. It also writes
`session-out/<ts>.tar.gz` with every step's evidence. Credentials come from
`.env` or the environment, and their values are redacted from the log and
the bundle. Use it on a machine with normal network access and hand back the
bundle.

* `make e2e-live` needs `MT5_*`. Named on the command line it never skips:
  without them it fails with `reason=env_missing` (rc 10). A live PASS means
  rules L1 to L6 below all hold, the run prints a `LIVE PASS:` line, and
  `result.txt` holds `reason=ok rc=0`.
* **2-minute live budget.** The first live tick must be recorded within
  `LIVE_BUDGET` seconds (default 120; `goldrec-e2e.sh --live-budget S`) of
  the terminal container starting, and again after the restart (a fresh
  container, timed from its own start). Otherwise it fails with the elapsed
  seconds and the phase reached: container started → EA connected
  (`terminal_connected`) → trade server connected (latest `terminal_info`)
  → first live tick. Each run prints, and writes to `timings.txt`, e.g.
  `start: ea_connected=41s trade_server=58s first_live_tick=63s (budget
  120s)`. The rest of `--min-ticks` may take longer, up to `--timeout` from
  the container start. `docker/mt5/test/goldrec_e2e_budget_test.sh` tests
  this logic without Docker.
* The login is config-only. `MT5_SERVER` must be `address:port` or a name
  listed in `config/servers.dat`: set `MT5_SERVERS_DAT` to a desktop MT5's
  copy (*File → Open Data Folder* → `config/servers.dat`). `mt5-state/`
  keeps the terminal's copy between sessions. The live check stops at once
  when the journal shows a fallback to MetaQuotes-Demo or `authorization on
  <MT5_SERVER> failed`.
* **`.env` wins.** A value in `.env` replaces the same name from the shell and
  from `make` (for example `BROKER_SYMBOL`), because `scripts/session.sh`
  sources the file after `make` has exported its defaults. Keep values that
  contain `$` in single quotes.

#### Live PASS rules (L1 to L6)

`scripts/goldrec-e2e.sh --require-live` (and so `make e2e-live`) passes only
when each rule holds for every container, the restarted one included. Each
rule reads only the current `run_id` and the connection under test (`conn`).
`MT5_EXPECT_SERVER` is the server the account must end on. It defaults to
`MT5_SERVER` when that is a name, is required when `MT5_SERVER` is
`address:port`, and may not be a `MetaQuotes-*` server.

| # | rule |
|---|---|
| L1 | `login` equals `MT5_LOGIN` and `server` equals `MT5_EXPECT_SERVER`, taken from the connection's `account` event, not from the hello |
| L2 | `trade_server_connected` is true in the same health poll |
| L3 | the window title holds the expected server and ` Account - `, read with `ui_main_window`; no `Read Only` in the title fails with rc 31 |
| L4 | the connection's first record is dropped, then at least 3 records with strictly rising `provider_time_msc` follow, received after the L1 event |
| L5 | for consecutive accepted records, `abs(Δprovider_time_msc − Δreceived_at)` is at most 30 s |
| L6 | the last accepted `provider_time_msc` is within 300 s of `server_time*1000` from the same poll |

A PASS prints `LIVE PASS: server=… symbol=… fresh=… first_live=… image=…
build=… company=…` and writes `reason=ok rc=0` to `result.txt`. A failure
writes `reason=<r> rc=<n>` to `result.txt`, prints `FAIL reason=<r>: …`, and
exits with `<n>`. rc 77 is never used, because `session.sh` reads it as SKIP.

| rc | reason | meaning |
|---|---|---|
| 1 | `unclassified` | the script exited outside the classifier; see the output above |
| 10 | `env_missing` | `MT5_LOGIN`, `MT5_PASSWORD` or `MT5_SERVER` not set |
| 11 | `env_unsafe` | a line of `.env` would be run by the shell; the key is printed, nothing ran |
| 12 | `expect_server_missing` | `MT5_EXPECT_SERVER` is needed, or it names a `MetaQuotes-*` server |
| 13 | `no_route` | `MT5_SERVER` is a name that no `servers.dat` lists |
| 14 | `route_unverified` | the state `servers.dat` has no `servers.dat.verified` marker for this server and file |
| 15 | `image_stale` | the image is missing, or was not built from the local `mql5/` and `docker/mt5` files |
| 16 | `broker_unreachable` | no TCP connection within 5 s to the `address:port` in `MT5_SERVER` |
| 20 | `compile_failed` | the EA did not compile; the compile line is printed |
| 21 | `ea_timeout` | the EA did not connect within the budget |
| 22 | `fallback_server` | the account is on another server than `MT5_EXPECT_SERVER` (the MetaQuotes fallback) |
| 23 | `auth_rejected` | the server rejected the login; the journal line is printed |
| 24 | `no_broker_connection` | no trade-server connection |
| 25 | `wrong_account` | the login or the server is not the expected one |
| 26 | `identity_conflict` | the window title disagrees with the account event, or no title could be read |
| 27 | `symbol_missing` | the broker symbol is not offered; the candidates are printed |
| 28 | `no_fresh_ticks` | the identity holds and the quote is fresh, but no rising ticks came |
| 29 | `stale_ticks` | ticks arrive but are old or out of pace (L5, L6) |
| 30 | `recorder_died` | goldrec exited; the end of its log is printed |
| 31 | `not_read_only` | the window title has no `Read Only` |
| 75 | `market_closed` | no fresh tick, and the last quote is older than 300 s on the broker clock. Inconclusive, not a PASS |

**Cloud sandbox limit (2026-11-04).** With an FTMO demo account
(`MT5_SERVER=FTMO-Demo`), the terminal never connected. The journal showed
`'<login>': connection to MetaQuotes-Demo lost`, and the status bar stayed at
`0 / 2 Kb`. In *File → Open an Account*, the broker-directory search for
"FTMO" never returned. The sandbox's outbound traffic goes through an HTTPS
proxy, and probing raw-TCP egress further was not permitted. So live broker
data can't be verified from the sandbox. Run `make session-live` elsewhere.

## 3. End-to-end runs (`scripts/e2e.sh`)

```bash
scripts/e2e.sh --build
```

This builds `gomql5/mt5:local`, then runs in host networking: it starts the Go
example on `127.0.0.1:7788` and the terminal container next to it, then waits
for the first tick.

```bash
scripts/e2e.sh --compose
```

This runs the same check through `docker-compose.yml`, with the EA reaching the
app by service name.

```bash
scripts/e2e.sh --keep
```

This leaves the terminal running afterwards, for use with `mt5ctl.sh`.

* **Pass/fail:** the output is `PASS` plus the hello and tick lines, or
  `FAIL: <reason>`. The script fails fast on a token mismatch, a compile
  failure, an unresolvable host or a dead container.
* **Evidence, always collected** into `e2e-out/<timestamp>/`:
  * `container.log`, `app.log.final`, `status.txt`
  * `terminal.log` (Journal), `compile.log`
  * `screen.png` (whole screen), `experts-log.png` (EA output)
* **On failure:** open `screen.png` first. In the injected-coordinate failure
  it showed the Options dialog stuck open with `127.0.0.1` typed but not
  confirmed, so the cause was visible immediately.

## 4. Visual walkthrough (`scripts/mt5ctl.sh`)

The container runs Xvfb at 1280×1024 with no window manager. The `mt5ctl.sh`
commands below run from the host against the only container labelled
`org.gomql5.role=mt5` (or `-c NAME`). Screenshots land in `./mt5ctl-out`
(`-o DIR`); read them with any image viewer or Claude's Read tool.

| command | shows / does |
|---|---|
| `status` | container health, terminal process, whether the EA holds a connection to the Go port |
| `shot [NAME] [options\|urllist\|toolbox\|WxH+X+Y]` | screenshot, optionally cropped |
| `goto experts-log` | Toolbox › Experts: the EA's `Print` output (connect errors, 4014 vs 5272) |
| `goto journal` | Toolbox › Journal: terminal log (config loaded, EA loaded/removed, LiveUpdate) |
| `goto options` / `goto allowlist` | Tools › Options › Experts: Algo Trading/WebRequest ticks and the allowed-URL list |
| `dismiss`, `click X Y`, `key K`, `type T` | drive the UI by hand |
| `logs terminal\|metaeditor\|compile [N]` | MT5's UTF-16LE logs, decoded |
| `conn [PORT]` | exit 0 if the EA's TCP connection is ESTABLISHED |
| `exec 'CMD'` | shell in the container with `lib.sh` loaded (`ui_*` functions) |

**What to look for:**

| symptom | where | meaning |
|---|---|---|
| `connect … not allowed (4014)` | experts-log | host not in the allowed-URL list (allowlist screenshot shows the list) |
| `connect … failed: 5272` | experts-log | allowed, but nothing listening (Go app down, wrong port) |
| `disconnected (read failed: 5273)` | experts-log | Go side closed (app exited, bad token) |
| `cannot load config "…""` | journal / `logs terminal` | start config path has spaces |
| `3 inputs read from … GoBridge.set` | journal | EA inputs applied |
| `expert GoBridge … removed` then `loaded` | journal | normal after Options › OK (settings change reloads EAs) |
| "Updates have been downloaded … Restart / Later" | screen | LiveUpdate modal: swallows keys, blocks Alt+F4; `dismiss` |
| "Select a company to open an account" | screen | account wizard (no login configured); harmless, `dismiss` |
| `authorization on MetaQuotes-Demo failed (Invalid account)` with another `MT5_SERVER` | journal | the server name is not in `config/servers.dat`: provide `MT5_SERVERS_DAT` or use `address:port` |

**Rules for driving the UI:**

* All coordinates and actions live in `docker/mt5/lib.sh`. If a build moves
  something, measure on a `shot` and change it there only.
* Use the mouse, not hotkeys. With no window manager, focus is unreliable:
  `Ctrl+O` once went into a chart's quick-navigation box.
* **One UI actor at a time.** `allow-host.sh`, the shutdown handler and
  `mt5ctl` UI commands share a `flock` lock. Without it, a retry and a
  walkthrough interleaved clicks and both derailed (reproduced, then fixed).
* The Experts tab content isn't written to `MQL5/Logs` until the terminal
  flushes it (minutes, or on exit), so the screenshot is the live source.

## 5. Investigating a failure: the loop

1. **Observe:** `e2e.sh --keep`, then `mt5ctl.sh status`, `goto experts-log`, `shot`.
2. **Hypothesise one cause** that explains *all* of the evidence.
3. **Run the smallest experiment** that tells the hypotheses apart (a raw
   socket listener, one UI action, one config line), and look at the result.
4. **Fix**, then **add a regression test** at the cheapest layer.
5. **Rerun e2e** (and the mode you didn't use: host vs compose).

Cases where this loop found the real cause:

| symptom | experiment | cause → fix |
|---|---|---|
| EA loaded, never connected; no EA log on disk | screenshot of Experts tab | 4014: allowed-URL list empty → UI automation (`allow-host.sh`) |
| Go: `handshake rejected: bad token` | raw Python listener printed the hello: `"token":"devtoken\r"` | `.set` writer left a CR on the last line → write CRLF on every line; EA trims |
| config ignored | Journal: `cannot load config "C:\Program Files\…""` | quoting of a spaced path → config moved to `C:\gobridge\` |
| `WebRequestUrl=` ini key had no effect | Options screenshot: box ticked, list empty | list is encrypted in `settings.ini` → not configurable by file |
| `app` never allowed | allowlist screenshot after typing `app`: entry gone | single-label names rejected → resolve to IP |
| setting lost on `docker stop` | screenshot during stop: LiveUpdate modal | modal swallowed Alt+F4 → Escape first |
| retries reported "no connection" forever | `ls /proc/net/tcp6` → missing; awk rc=2 | read only existing tables |
| `wineboot` hung 300 s at build | wineboot without Xvfb worked | Mono/Gecko prompt → `WINEDLLOVERRIDES="mscoree,mshtml="` |
| live FTMO login (user's host, build 6300): `allow-host: terminal window not found`, EA never connects | renamed the window here to `<login> - FTMO-Demo: Demo Account - …` → same message | logged-in title drops "MetaTrader 5" → find the window by class `terminal64` (`ui_main_window`); `windows.txt` in the e2e evidence |
| `MT5_SERVER=FTMO-Demo`: journal `authorization on MetaQuotes-Demo failed (Invalid account)` | user's screenshots: the directory search finds "FTMO Global Markets Ltd" | stock terminal doesn't know the server and falls back to MetaQuotes-Demo → `ui_login_existing` (File › Open an Account › company › Next › existing account › server-list entry N › Finish); `goldrec-e2e.sh --require-live --find-broker FTMO` tries entries until the bridge reports a trade-server connection. **Removed (see the servers.dat row below)** |
| wizard login tried 5 servers, all "Invalid account" (user's run, build 6300) | `login-*-servers.png`: FTMO's list is Server4, Server5, Server, Server3, Server2, **Demo** (not alphabetical); the account's FTMO-Demo was entry 5 | 5 tries ended one short → up to 12 tries, each ends as soon as the journal logs `authorization on <server> failed`; stops with a reason when MT5_SERVER itself rejects the login or the list repeats; a restart starts at the entry that worked (`goldrec_e2e_login_loop_test.sh` simulated this list). **Removed with the wizard** |
| logged in to FTMO-Demo (`authorized`, `synchronized … 166 symbols`, live EURUSD on screen) but 0 XAUUSD ticks in 10 min | timeline: goldrec subscribed 23:43:39, account synchronized 23:43:44; the EA's PollTicks skips a failing `SymbolInfoTick` silently | the sync can drop a symbol selected before it → goldrec re-selects + re-subscribes when the trade server connects and after 10 s of silence (`-resync-quiet`, default 10 s), and records a `symbol_resync` event (selected?, quote and its time, errors). Live ticks on FTMO not yet confirmed |
| positional server picks are slow (~2 min/entry) and FTMO's order changed between runs | `wincombo list` under Wine against the wizard: the server list is a standard Win32 `ComboBox` (entries readable; the A APIs returned only "M", the W APIs the full text); `select` on a 3-entry Options combo moved it to entry 2 on screen | pick `MT5_SERVER` by name with window messages (`ui_login_existing … name`, `docker/mt5/tools/wincombo.c`, built by mingw in the image); a missing server fails at once with the list; positions remain the fallback. **Removed with the wizard** (helper, `wintools` image stage) |
| `MT5_SERVERS_DAT` installed but ignored | listing both folders in a running container: the terminal wrote terminal.ini/common.ini and a fresh 7544-byte servers.dat into `config/` (created by the entrypoint) while `Config/servers.dat` (26492 bytes, the installer's) stayed untouched | Linux keeps `Config` and `config` apart, Wine picks the lowercase one → the entrypoint no longer creates `config/`; `mt5_config_dir` picks the folder the terminal uses (existing `config` first, else `Config`). Verified: one folder, the installed servers.dat sits next to the terminal's own files, and the state copy is saved |
| can the WebRequest allow-list (needed by SocketConnect) be set without UI? | per-variant containers with `GOBRIDGE_AUTO_ALLOW=0`: `[Experts] WebRequestUrl=` (IP, `http://IP`, `IP:port`, several entries), the same keys in `config/common.ini`, and copying the encrypted `settings.ini` (+ common.ini/terminal.ini) saved after a successful allow-host run | **no**: every variant logged `connect … not allowed (4014)`; no `experts.ini` is ever created; the list does not even survive a restart of the same container. `allow-host.sh` (UI) stays, run on every start |
| `goto experts-log` showed the "Company" tab when logged in | user's logged-in screenshot: Trade/Exposure/History/…/Company tabs added | Toolbox layout depends on the login → `ui_account_authorized` (title has " Account - ") picks the tab position |
| page 2 of that wizard ignored typed login/password 6 s after Next | same steps on a page left open for a minute worked | the page settles slowly → wait 20 s, fill twice (Ctrl+A makes it idempotent). **Removed with the wizard** |
| why does a config login to `FTMO-Demo` fall back at all? | MetaQuotes documents `[Common] Server` as "address and port … separated with a colon"; a name resolves only through `config/servers.dat`, which the stock install fills with MetaQuotes servers | the wizard was a workaround for a missing file → **wizard removed** (cursor-driven, slow, coordinates unverified for found companies, positions shifted between runs). Login is config-only: install a `servers.dat` that knows the broker (`MT5_SERVERS_DAT`, from a desktop MT5's data folder) or use `address:port`; the terminal's copy is kept in `GOMQL5_STATE_DIR` (`mt5-state/` in sessions). `goldrec-e2e.sh` fails fast with that advice when the journal shows the fallback or `authorization on <MT5_SERVER> failed` (`goldrec_e2e_login_test.sh`, `servers_dat_test.sh`) |
| walkthrough screenshot showed the wrong tab | ran allow-host and `goto` concurrently | UI race → `flock` |

## 6. Sandbox / CI environment notes

Cloud sessions are containers. Docker is installed, but the daemon may not be
running, and outbound traffic goes through a TLS-intercepting proxy.

```bash
nohup dockerd > /tmp/dockerd.log 2>&1 &
```

```bash
E2E_CA_CERT=/root/.ccr/ca-bundle.crt BASE_IMAGE=mirror.gcr.io/library/debian:trixie-slim GO_IMAGE=mirror.gcr.io/library/golang:1.24-bookworm scripts/e2e.sh --build
```

* `E2E_CA_CERT` passes the proxy CA as a build secret. When `HTTPS_PROXY` is
  set, `e2e.sh` also adds `--network host` and the proxy build args.
* The mirror images avoid Docker Hub's 429 rate limit.
* `E2E_IMAGE=gomql5/mt5:<tag>` builds/runs another tag with `scripts/e2e.sh`
  and `scripts/goldrec-e2e.sh`, so a trial image doesn't replace `:local`.
* A container on a compose bridge network can't reach the proxy, so
  `apt-get` inside it fails. That's why ImageMagick is baked into the image.
* **Disk:** each image is ~4.4 GB (7.3 GB before the cuts in `docs/docker.md` "Image size"), and repeated builds pile up build cache.
  In session 2 the disk filled to 100 %. Check `df -h /` and prune with
  `docker builder prune -af` and `docker image prune -f`.
* There's no broker account in the sandbox: the terminal runs against bundled
  history (`connected=false`, `login=0`).

## 7. Known limits of the current checks

* Broker login, `order_send`, positions, history and `copy_ticks_range` have
  only been tested against the FakeEA.
* `allow-host.sh` coordinates are tied to the measured build. When they break,
  `e2e.sh` fails with "no tick", and `screen.png` shows where the sequence
  stopped.
* When the Go app connects only briefly (e.g. `-ticks 1`), the entrypoint's
  connection watcher can miss it and retry allow-host. That's harmless: the
  terminal de-duplicates list entries (verified on screen).
