# Working on gomql5

Start each session by reading `docs/ROADMAP.md` (status and next item),
`docs/protocol.md` (wire contract) and `docs/TESTING.md` (how work is verified
here, and how to look inside the running terminal).

## Commands

```bash
go vet ./... && go test -race -count=1 ./...
```

```bash
make session
```

This runs every layer (tests, fuzz, image, probes, e2e, and the live e2e when
`MT5_*` is in `.env`) into one redacted log plus a bundle under
`session-out/`. `make help` lists the single-step targets.

```bash
for t in docker/mt5/test/*_test.sh; do bash "$t"; done
```

```bash
scripts/e2e.sh --build
```

This builds the image, runs the real terminal next to the Go example, and
passes on the first tick. Without a broker account that tick is the
terminal's cached quote, not live data (`docs/goldrec.md` §4). `--compose`
runs the same check through docker-compose. `--keep` leaves the terminal
running.

```bash
scripts/goldrec-e2e.sh --broker-symbol EURUSD --min-ticks 1 --restart
```

This runs the gold positioning recorder (`apps/goldrec`, `docs/goldrec.md`)
against the real terminal, including a reconnect. Without an account, use
EURUSD: XAUUSD has no cached quote.

```bash
scripts/mt5ctl.sh status
```

```bash
scripts/mt5ctl.sh goto experts-log
```

These look at the running terminal (see `-h` for the other screens, logs and
UI actions).

* **Behind a TLS-intercepting proxy:** add `--network host --secret id=ca_cert,src=<ca.crt>`
  plus the `HTTP(S)_PROXY` build args.
* **If Docker Hub returns 429:** add
  `--build-arg BASE_IMAGE=mirror.gcr.io/library/debian:trixie-slim`.
* `scripts/e2e.sh` takes these from the environment (`E2E_CA_CERT`,
  `HTTPS_PROXY`, `BASE_IMAGE`, `GO_IMAGE`). Cloud-sandbox specifics (starting
  `dockerd`, disk pruning) are in `docs/TESTING.md` §6.

Regenerate the constants after a `MetaTrader5` release; see the header of
`tools/genconst/genconst.py`.

## Rules

* A protocol change touches four places in the same commit:
  `mql5/Experts/GoBridge/GoBridge.mq5`, `mt5/api.go`, `mt5/mt5test` (if
  needed) and `docs/protocol.md`.
* Requests stay flat (scalar params only). `protocol.Request` enforces this.
* Every new behaviour gets a FakeEA test. When adding a check, prove it can
  fail: inject the bug, watch the test fail, revert.
* MQL5 code can only be compiled with MetaEditor (Windows or Wine). The
  Docker entrypoint compiles it and prints the log. Say clearly whether MQL5
  changes were compiled.
* **Changes to the EA, the image, or assumptions about MT5 behaviour are done
  only when `scripts/e2e.sh` passes.** Quote its PASS line. If it can't run,
  say so and list the change as unverified.
* **When the terminal misbehaves, look before theorising.** Take a
  `scripts/mt5ctl.sh shot` / `goto …` and read the screenshot, then run the
  smallest experiment that separates the hypotheses (`docs/TESTING.md` §5).
* UI coordinates and actions live only in `docker/mt5/lib.sh`. Drive menus
  with the mouse, and take the UI lock (`ui_lock`) in anything that clicks.
* Don't commit `.env`, credentials or `.ex5` files.
