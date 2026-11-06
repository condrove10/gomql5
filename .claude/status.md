# Status

## Current

| Task | Stage | Mode | Ultracode | Updated |
|---|---|---|---|---|
| Live E2E | Experiments done: `make e2e-live` passes on FTMO-Demo; hardening not built, waiting on the user | ATTENDED | Harness on; phrase not sent | 2026-11-05 |

## Worktrees

No gitGraph or worktree data: this directory is not a git repository.

| Worktree path | Branch | Task | Stage | Last commit | Next step | Tier |
|---|---|---|---|---|---|---|
| (this directory) | none | Makefile round | Finish | none | User decides on the hardening and the repository; containers gomql5-vnc, gomql5-novnc, gomql5-netcap still running | top |

## Tasks

| Number | Task | File or symbol | Check | Tier | State |
|---|---|---|---|---|---|
| 1 | check, shell, fuzz, probes, test, build, goldrec, guards, clean | `Makefile` | rc and SUMMARY lines, checked by top tier | cheap | Done, no failures; probe-api SKIP (no Myfxbook credentials) |
| 2 | image, e2e, e2e-goldrec | `Makefile` | PASS lines | cheap | PASS; cached quotes only |
| 3 | e2e-live | `Makefile`, `scripts/goldrec-e2e.sh` | first live tick within 120 s | cheap | PASS after a manual login saved `servers.dat`; first attempt failed on the MetaQuotes-Demo fallback |
| 4 | Static audit of Makefile and session.sh | `.claude/outputs/makefile-round-20261105.md` | top-tier check of each finding | top | 12 findings confirmed, none fixed |
| 5 | Live E2E proposal | `.claude/outputs/live-e2e-proposal.md` | adversarial review applied | top | Written, experiments recorded in §12; §5 not built |

## Decisions

| Date | Decision | Reason | By |
|---|---|---|---|
| 2026-11-05 | Run terminal targets one at a time | Host-network containers share fixed ports | Agent choice, reported to user |
| 2026-11-05 | Do not run `make clean-docker` | Prunes build cache and dangling images for the whole host | Agent choice, reported to user |
| 2026-11-05 | Route to FTMO-Demo: one manual login in the image | The user's login; `mt5-state/servers.dat` then carries config-only logins | User |
| 2026-11-05 | `.env` holds the read-only password only | `scripts/session.sh` asks for the investor password | Agent choice, reported to user |
