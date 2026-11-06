# Shared facts for agent briefs

- Repository: created by `git init` here on 2026-11-05 (AFK, no clone given). Base `main`, working branch `e2e/hardening`. No remote.
- Hard limit: no push, no deploy, no deleting branches or data, no sending data out.
- Off-limits: `.env` (never read or print), `mt5-state/`, `session-out/`, containers `gomql5-vnc`, `gomql5-novnc`, `gomql5-netcap`, `gomql5-netcap-host` and the recording. Never run `make clean`, `make clean-docker` or `docker` against them.
- Plan: `.claude/outputs/live-e2e-proposal.md`; §4 and §5 are the spec, §12 the live results. No code may send a real login with wrong credentials (D3 = a).
- Vetting: `go vet ./... && go test -race -count=1 ./...`; `for t in docker/mt5/test/*_test.sh; do bash "$t"; done`; `scripts/e2e.sh --build`; `make e2e-live`.
- Host: go1.26.4, docker 29.5.3, GNU Make 4.4.1, gopls v0.23.0; image `gomql5/mt5:local` (MT5 build 6300). Shared WSL2 Docker host with unrelated containers.
- Only the coordinator runs real-terminal targets, one at a time: they use host networking and fixed ports. Builders use stubs and FakeEA only.
- `.env` values with `$` must stay single-quoted: `scripts/session.sh` sources it.
- Commit trailers: Stage, Area, Worktree, Next, then the Co-Authored-By line. Title `<area>: <change>`. Each builder updates only its own files; the coordinator updates `.claude/status.md` at each merge, so parallel branches do not conflict.
