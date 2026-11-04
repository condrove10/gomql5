# Working on gomql5

Start each session by reading `docs/ROADMAP.md` (status and next item) and
`docs/protocol.md` (wire contract).

## Commands

```bash
go vet ./... && go test -race -count=1 ./...
```

```bash
docker build -f docker/mt5/Dockerfile -t gomql5/mt5:dev .
```

* **Behind a TLS-intercepting proxy:** add `--network host --secret id=ca_cert,src=<ca.crt>`
  plus the `HTTP(S)_PROXY` build args.
* **If Docker Hub returns 429:** add
  `--build-arg BASE_IMAGE=mirror.gcr.io/library/debian:trixie-slim`.

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
* Don't commit `.env`, credentials or `.ex5` files.
