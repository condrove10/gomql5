# goldrec: gold positioning recorder

`apps/goldrec` records **Myfxbook XAUUSD aggregate positioning** (long/short
percentages, lots, position counts, average entry prices) and, as a separate
series, **broker gold ticks** from a GoBridge EA. It writes append-only JSON
Lines, so the data can be inspected later. It is not a trading bot: it contains
no order calls and produces no signals.

Status as of 2026-11-04: **the local product works; live acquisition is not
activated.** No Myfxbook credentials and no broker account were available, so
positioning has only run in labelled replay mode, and the real terminal had no
trade-server connection (cached quotes only). See §5.

## 1. Run it

```bash
go build -o bin/goldrec ./apps/goldrec
```

Paid API pilot (60 s, 1,440 outlook requests a day plus logins, under the
documented 2,880 allowance):

```bash
MYFXBOOK_EMAIL=… MYFXBOOK_PASSWORD=… GOBRIDGE_TOKEN=… bin/goldrec -source api -entitlement paid -interval 60s -budget 2880 -listen :7788 -out goldrec-data
```

Free pilot (100 requests a day per the docs, so about 15 min):

```bash
MYFXBOOK_EMAIL=… MYFXBOOK_PASSWORD=… bin/goldrec -source api -entitlement free -interval 15m -budget 100 -listen "" -out goldrec-data
```

One authenticated probe (login plus one outlook, then exit):

```bash
MYFXBOOK_EMAIL=… MYFXBOOK_PASSWORD=… bin/goldrec -source api -once -out goldrec-probe
```

No vendor access: synthetic fixtures, labelled `source_mode:"replay"`:

```bash
GOBRIDGE_TOKEN=… bin/goldrec -source replay -interval 15s
```

The broker side is the usual container (`docker compose up`, or
`docker run … gomql5/mt5:local`) with `MT5_LOGIN`/`MT5_PASSWORD`/`MT5_SERVER`
set and `GOBRIDGE_PORT` pointing at goldrec. Use `-broker-symbol` for brokers
that call gold `GOLD`, `XAUUSD.r` and so on. If the symbol is missing, goldrec
logs the `*XAU*,*GOLD*` candidates and records a `broker_symbol_unavailable`
event.

Stop it with SIGINT or SIGTERM. It flushes on the way out. Run it under a
supervisor (systemd `Restart=always`, or compose `restart: unless-stopped`).
Run only one goldrec per Myfxbook account, because the ledger and session are
per process.

| flag / env | default | meaning |
|---|---|---|
| `-source` | `api` | `api`, `replay` or `none` (prices only) |
| `-interval` | `60s` | positioning poll period |
| `-budget` | `100` | vendor requests per rolling 24 h. Every login, outlook and failed request counts. |
| `-ledger` | `<out>/ledger.log` | persistent request ledger |
| `-entitlement` | `unknown` | written on every record as declared, never inferred |
| `-listen` | `:7788` | EA address. Empty disables prices. |
| `-broker-symbol` | `XAUUSD` | broker gold symbol |
| `-provider-symbol` | `XAUUSD` | symbol name in the Myfxbook response |
| `-out` | `goldrec-data` | data directory |
| `-once`, `-duration` | | probe, or a bounded run |
| `MYFXBOOK_EMAIL`, `MYFXBOOK_PASSWORD` | | vendor login. Never logged or archived. |
| `GOBRIDGE_TOKEN` | | EA shared token |

## 2. What is recorded

Every line carries `schema:"goldrec/1"`, a stable `id` (`<run_id>-<stream>-<seq>`),
the `run_id` and the per-stream `seq`. All collector times are UTC.

| file | one line per | key content |
|---|---|---|
| `attempts.jsonl` | request to the vendor, or replay read | method, request start, response end, duration, HTTP status, `status` (see below), redacted message, body sha256, `raw_ref`, budget used and remaining |
| `sentiment.jsonl` | XAUUSD observation from a successful response | `supplied` (the vendor's exact decimal text, e.g. `"836.10"`), `derived` (our `long_volume_share`, `long_count_share`, `sum_positions`, `percentage_sum`, `total_matches_count`), `quality` flags, `collected_at`, `provider_time:null` with a note, `same_as_previous`, `source_mode`, `entitlement`, `raw_ref` |
| `quarantine.jsonl` | observation that can't be interpreted (a missing, null or invalid required field) | same shape, `quarantined:true`, never zero-filled |
| `prices.jsonl` | broker tick | feed, broker company/server/login, broker symbol, instrument, bid/ask/last/volume/flags, `provider_time_msc` verbatim, the broker wall-clock text, `trade_server_connected`, `received_at` |
| `events.jsonl` | run start/stop, terminal connect/disconnect, `terminal_info`, `instrument` metadata (digits, contract size, currencies), quality events (`symbol_absent`, `unknown_top_level_fields`, `broker_symbol_unavailable`) | |
| `raw/ab/<sha256>.json.gz` | distinct outlook body (all symbols), verbatim | linked from attempts and observations by `raw_ref`. Login bodies are never archived. |
| `status.json` | health snapshot (every 5 s) | attempts by status, last attempt, last observation, last value change, budget, terminal state, tick count, dropped ticks, last error |

Attempt `status` values:

* `ok`
* `transport_error`
* `http_error` (a Cloudflare challenge is named as such)
* `parse_error`
* `app_error` (`{"error":true}`)
* `session_invalid`
* `budget_exhausted`
* `login_throttled`
* `no_credentials`

Quality flags:

* `missing:F`, `null:F`, `invalid:F` (these quarantine the record)
* `numeric_string:F`
* `negative:F`
* `non_integer:F`
* `unknown_field:F`
* `zero_denominator:volume|positions`
* `total_mismatch`: `totalPositions` differs from long + short
* `percentage_sum_off`: the sum is more than 1 away from 100

Inspect the data with any JSON tool. For example:

```bash
jq -c '{t:.collected_at, L:.supplied.longPercentage, S:.supplied.shortPercentage, lots:[.supplied.longVolume,.supplied.shortVolume], q:.quality}' goldrec-data/sentiment.jsonl
```

```bash
zcat goldrec-data/$(jq -r .raw_ref goldrec-data/sentiment.jsonl | tail -1) | jq '.symbols[] | select(.name=="XAUUSD")'
```

## 3. Behaviour that matters for data quality

* **Unchanged values are recorded.** Every successful poll is an observation.
  `same_as_previous` marks repeats, and `status.last_value_change_at` tracks
  changes. Identical bodies share one raw object, but their observations stay
  separate.
* **No invented times.** The API supplies no observation time, so
  `provider_time` is `null`. Broker tick time is `time_msc` verbatim (the
  broker server's wall clock, offset unknown), stored next to our UTC
  `received_at`.
* **Sessions.** The client logs in on demand. On `Invalid session.` it tries
  one re-login, and at most one login per 10 min, so an IP-bound or revoked
  session can't loop. The session lives in memory only: each restart costs
  one login.
* **Budget.** Every request is reserved in the ledger, and the ledger is
  fsynced before the request is sent. The window is a rolling 24 h. A
  restart keeps the count. When the budget is spent, polls are recorded as
  `budget_exhausted` and nothing is sent.
* **Secrets.** The email, password and session go only in the request URL,
  because that is the documented API form. Transport errors are stripped of
  the URL, and messages are redacted, both raw and URL-encoded.
* **Durability.** Attempts, observations and events are fsynced per line.
  Ticks are flushed every second, so a crash loses at most about 1 s of
  ticks. A store write failure stops the recorder with an error, so data is
  never dropped silently. `DroppedTicks` (the bridge's back-pressure counter)
  goes into events and status.
* **Prices and positioning are separate series.** The instrument label of a
  price feed is `XAUUSD` only when the broker symbol looks like gold. A
  non-gold feed keeps its own name.

## 4. How it was verified (2026-11-04)

| check | result |
|---|---|
| `go vet ./... && go test -race -count=1 ./...` | all packages `ok` |
| Adapter tests (`apps/goldrec/myfxbook`) | parsing, quirks (numeric strings, null, NaN/Inf/hex strings, negatives, non-integers, unknown fields, zero denominators, total mismatch), vendor statuses incl. a Cloudflare 403, re-login once then throttle, budget enforcement + restart + torn ledger line + window expiry, secret redaction, no-credentials sends nothing, the captured real error bodies |
| Recorder tests (`apps/goldrec/record`) | replay labelling, repeats kept, quarantine, `raw_ref` resolves to the exact body, failed attempt gives no observation, FakeEA prices + reconnect re-subscribe, wrong broker symbol with candidates, store failure stops the run, shutdown while idle, instrument labels |
| Checks shown able to fail | 16 injected bugs, each caught by its test and clean after revert. Plus two real defects found in review (price instrument mislabelled; shutdown hang with a wrong symbol), each with a test seen failing before the fix. |
| Vendor reachability (unauthenticated `curl`) | `api/*.json` reachable from this sandbox: HTTP 200, `{"error":true,"message":"Invalid session."}` / `"Required fields missing."`. `www.myfxbook.com/community/outlook/XAUUSD` and `/api` (the docs page): HTTP 403 Cloudflare challenge (not bypassed). |
| Real terminal (`scripts/goldrec-e2e.sh`) | **PASS** with `--broker-symbol EURUSD --min-ticks 1 --restart`: 2 connections, a tick recorded after the restart, positioning replay alongside. The ticks were the cached 2024-08-23 quote with `trade_server_connected:false`. **FAIL (correctly) with XAUUSD:** symbol present (`Gold vs US Dollar`, contract 100), subscribed, but no quote and no history (`CopyRates` error 4401), because the terminal has no account. |

The existing `scripts/e2e.sh` PASS has the same cause: its "tick" is the
cached EURUSD quote, sent once when the EA first polls. It proves the bridge
path, not live market data.

## 5. Capability status and limitations (decision register)

| item | status |
|---|---|
| 15 s positioning capture | **Unresolved source dependency.** The API allowance (2,880 a day, documented) is below 5,760, and the indicator (the 15 s path) has no verified export. goldrec allows a 15 s interval, but the budget then stops requests when it runs out. |
| 60 s paid API pilot | Implemented, not run: there are no credentials. |
| API field names and semantics | Taken from the handoff's record of the docs (the docs page is now Cloudflare-blocked here). Unknown or missing fields are flagged, not guessed. Percentage denominators and the volume units are unverified. |
| Session URL-encoding | Sessions containing `%` are decoded once before reuse (an assumption; check on the first real login). |
| Quota window | Treated as a rolling 24 h with every request counted (conservative). Fixed-window and burst rules are unverified. |
| Broker gold prices | Implemented and run against the real terminal. Live ticks need a broker (demo) account: not available here. |
| MT4/MT5 Myfxbook indicator exporter | Not started. It needs the vendor indicator installed and a verified buffer contract. The supplied installer was not run (no authorisation). |
| Website endpoints (`/outlook-data.json`, …) | Not used. The page is behind a Cloudflare challenge, and they are not a documented API. |
| Storage | JSONL plus a gzip raw archive. Deliberately replaceable (SQLite next). No automatic deletion. The ledger file is never compacted (about 120 KB a day at 60 s). |
| Viewer, exports, Discord, hosting | Not started (out of scope for this step). |

### Credentialed attempt (2026-11-04, cloud sandbox)

An FTMO demo account was tried with its read-only password (never committed or
logged). The terminal took the login, but it bound it to `MetaQuotes-Demo`
(`connection to MetaQuotes-Demo lost`) and never reached a trade server. The
stock terminal has no `FTMO-Demo` entry, and the in-terminal broker search
for "FTMO" did not return from the sandbox. Result: no live XAUUSD ticks.
`scripts/goldrec-e2e.sh --require-live` correctly fails in that state.

Cause, found later: a config login only resolves a server *name* that the
terminal's `config/servers.dat` lists, and the stock file lists MetaQuotes
servers only. The fix is a `servers.dat` that knows the broker (or an
`address:port` server), see §6. Re-run on a machine with normal network
access:

```bash
make session-live
```

## 6. What it takes to go live

1. **Myfxbook credentials.** Run `-source api -once`, then read
   `attempts.jsonl` and the raw body. Confirm the field names and the session
   format, and record what you find here.
2. **A broker account.** Even a demo account works, at a broker whose gold
   symbol you choose. Put `MT5_LOGIN`, `MT5_PASSWORD` and `MT5_SERVER` in
   `.env`. The login is config-only (no UI automation), so the terminal must
   be able to resolve `MT5_SERVER`:
   * a **name** (`FTMO-Demo`) has to be listed in `config/servers.dat`. Copy
     that file from a desktop MT5 that has logged in to the broker once
     (*File → Open Data Folder* → `config/servers.dat`) and add
     `MT5_SERVERS_DAT=/path/to/servers.dat` to `.env`;
   * or set `MT5_SERVER=address:port` and skip `servers.dat`.

   `mt5-state/` keeps the terminal's own copy of `servers.dat` between
   sessions, so after one successful login the config alone is enough. Then
   run:

   ```bash
   make session-live
   ```

   This runs `goldrec-e2e.sh --require-live`, which passes only on
   `trade_server_connected:true` ticks. It fails at once, naming the fix,
   when the journal shows a fallback to MetaQuotes-Demo or `authorization on
   <MT5_SERVER> failed`.
3. **A host** with stable egress, because the docs say sessions are bound to
   the login IP. Run goldrec under a supervisor, then do a 24 h observation
   run plus a restart/outage exercise.
