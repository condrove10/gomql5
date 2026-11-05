# gomql5 - developer and verification targets.
#
#   make session           everything, end to end, one log: session-out/<ts>/session.log (+ .tar.gz)
#   make session-live      same, but stop early if the account step is skipped (no MT5_* set)
#   make help              list targets
#
# Every verification target goes through scripts/session.sh, so each one leaves
# a timestamped, secret-redacted log and evidence bundle under session-out/.
# Credentials: put MT5_LOGIN / MT5_PASSWORD (read-only/investor password) /
# MT5_SERVER (plus MT5_SERVERS_DAT unless MT5_SERVER is address:port) and
# optionally MYFXBOOK_EMAIL / MYFXBOOK_PASSWORD in .env (never committed), or
# export them. Override the file with E2E_ENV=path.

SHELL := /bin/bash
SESSION := scripts/session.sh

# Tunables (also read by session.sh from the environment)
FUZZTIME ?= 20s
BROKER_SYMBOL ?= BTCUSD
POSITIONING_SOURCE ?= replay
E2E_TIMEOUT ?= 600
LIVE_BUDGET ?= 120
export FUZZTIME BROKER_SYMBOL POSITIONING_SOURCE E2E_TIMEOUT LIVE_BUDGET

# A noexec /tmp breaks `go test` ("fork/exec …: permission denied"): Go runs
# test binaries from its work dir. scripts/gotmpdir.sh picks a usable one.
GOTMPDIR := $(shell bash scripts/gotmpdir.sh)
ifneq ($(GOTMPDIR),)
export GOTMPDIR
endif

.DEFAULT_GOAL := help
.PHONY: help session session-live check test shell fuzz image probe probe-net probe-api \
	e2e e2e-goldrec e2e-live build goldrec clean clean-docker

help: ## list targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'
	@echo
	@echo "  Tunables: FUZZTIME=$(FUZZTIME) BROKER_SYMBOL=$(BROKER_SYMBOL)"
	@echo "            POSITIONING_SOURCE=$(POSITIONING_SOURCE) E2E_TIMEOUT=$(E2E_TIMEOUT) LIVE_BUDGET=$(LIVE_BUDGET) E2E_ENV=.env"

## --- full sessions -----------------------------------------------------------
session: ## ALL steps: env, check, shell, fuzz, image, probes, e2e, e2e-goldrec, e2e-live -> one log + bundle
	$(SESSION)

session-live: ## the steps that matter for a live account: env, image, probes, e2e-live
	@bash scripts/envlint.sh "$${E2E_ENV:-.env}" || exit 11; source "$${E2E_ENV:-.env}" 2>/dev/null; [ -n "$$MT5_LOGIN" ] || { echo "MT5_LOGIN not set (in .env or the environment)"; exit 2; }
	$(SESSION) env image probe-net probe-api e2e-live

## --- individual steps (each also writes a session log) ------------------------
check: ## go vet + go test -race (unit, FakeEA mocks, fuzz seed corpora)
	$(SESSION) env check

shell: ## container helper shell tests
	$(SESSION) shell

fuzz: ## run every fuzz target for FUZZTIME each
	$(SESSION) fuzz

image: ## build the gomql5/mt5:local image (HTTPS_PROXY, E2E_CA_CERT, BASE_IMAGE, GO_IMAGE honoured)
	$(SESSION) env image

probe: ## network + Myfxbook API probes (API probe needs MYFXBOOK_* credentials)
	$(SESSION) env probe-net probe-api

probe-net: ## host egress probes only
	$(SESSION) probe-net

probe-api: ## one authenticated Myfxbook round (goldrec -source api -once)
	$(SESSION) probe-api

e2e: ## bridge smoke test against the real terminal (scripts/e2e.sh)
	$(SESSION) e2e

e2e-goldrec: ## recorder pipeline against the real terminal, with a restart (no account needed)
	$(SESSION) e2e-goldrec

e2e-live: ## recorder with a broker account: first live tick within LIVE_BUDGET s of container start (MT5_* set)
	$(SESSION) env e2e-live

## --- plain developer targets (no session log) -----------------------------------
test: ## fast: go vet + go test -race
	go vet ./... && go test -race -count=1 ./...

build: ## build the example and the recorder into bin/
	go build -o bin/basic ./examples/basic
	go build -o bin/goldrec ./apps/goldrec

goldrec: build ## run the recorder locally (replay positioning, EA on :7788); ARGS=... to override
	GOBRIDGE_TOKEN=$${GOBRIDGE_TOKEN:-dev-token} bin/goldrec $(or $(ARGS),-source replay -interval 15s -listen :7788)

clean: ## remove local outputs (keeps session-out/)
	rm -rf bin e2e-out mt5ctl-out goldrec-data

clean-docker: ## stop leftover test containers and prune build cache (frees disk)
	-docker ps -q --filter label=org.gomql5.role=mt5 | xargs -r docker stop -t 30
	docker builder prune -af
	docker image prune -f
