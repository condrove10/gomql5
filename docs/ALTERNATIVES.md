# Headless and config-only alternatives (evaluated 2026-11-05)

Two steps still drive the terminal's UI:

* `allow-host.sh` clicks through Tools › Options to allow-list the Go host.
  MQL5 `SocketConnect` needs that list.
* Xvfb provides an X display for it.

This note records the alternatives we tested so a choice can be made. The
prototypes ran in real containers from `gomql5/mt5:local` (MT5 build 6300,
wine-staging 11.21). They are **not** in the code yet, and none has been
through `scripts/e2e.sh`.

Ground rule: use documented MetaTrader features only. MetaQuotes' encrypted
settings were not decrypted and no binaries were patched.

## Findings

| # | Approach | Result | Removes | Cost / risk |
|---|---|---|---|---|
| A | **DLL socket bridge**: `[Experts] AllowDllImport=1` in the `/config` ini; the EA `#import`s a ~70-line mingw DLL (`ws2_32`: connect/send/recv/close) | **Works.** The EA printed `REPLY=[ACK-FROM-HOST-OK]` and the listener got `HELLO-FROM-DLL`. Compile 0 errors, no dialogs, ~2 ms round trip | `allow-host.sh` and all start-up UI clicks | Enabling DLL imports lets EAs run any native code, which is broader than a per-host allow-list (a policy decision). EA socket calls change; the wire protocol does not |
| B | **Shared-file bridge**: JSON lines in `MQL5/Files` on a bind mount | **Works.** Tick→Go median 0.1–0.6 ms (p95 ≤1.1 ms). Round trip median 1.3–5 ms. 20 000 lines arrived complete and in order | sockets and the allow-list | Partial lines; the inbox must be reopened on every poll; rotate by generation; replay on restart; 25–36 % CPU at 1–2 ms timers (5–10 ms suggested). inotify is unreliable on Docker Desktop, so poll as a fallback |
| C | **Wine without X**: `HKCU\Software\Wine\Drivers` `Graphics=null`, no Xvfb | **Works.** Compile, terminal and EA ran for 7 min with no new errors. RAM 312 MiB vs 353 MiB with Xvfb (−12 %), same CPU | Xvfb and VNC | Screenshots, `mt5ctl goto` and xdotool shutdown stop working (`wineserver -k` is not a clean exit). On its own the EA stays at 4014, because the allow-list needs UI; it only makes sense together with A or B |
| D | **Built-in MCP server** (`Config/assistant.ini`: `Endpoint=http://127.0.0.1:22346/mcp`, `Authorization: Bearer <ApiKey>`, streamable HTTP) | **Partial.** Auth and transport were verified, but calls return 401 while the terminal is not signed in to MQL5.community | possibly the EA, for quotes and history | Needs an MQL5.community login. It also exposes trading and `shell` tools, so keep it loopback-only or set `Enable=0` |
| E | **`[Common] Server=host:port`**, the documented login format | The quoted text ("Enter its IP address and port number as [server number]:[port number]") is from the login dialog's help. The `[Common] Server` key is documented on the Platform Start page. Not tested here | `servers.dat` | You learn your own access point with `ss`/netstat on a logged-in terminal or from the broker; access points can rotate |
| F | **`servers.dat` login** (current) | Implemented and verified (one config folder; installed file used) | the account wizard | A remark in a forum thread (from a user whose account was later deleted, not a moderator's ruling) calls the file internal and not meant for third-party tools; copying it is unsupported |

## What was ruled out

| Idea | Why it is out |
|---|---|
| Config-only allow-list | Every variant failed with 4014: `[Experts] WebRequestUrl=` in the `/config` ini or `common.ini` (IP, `http://IP`, `IP:port`, several entries), and copying the encrypted `settings.ini`. No `experts.ini` is created on this build, and the list does not survive a restart |
| Windows containers | Microsoft does not support a GUI in them. They need a Windows host, and the `windows/server` base is about 3 GB before MT5 |
| Other architectures | No ARM or native Linux MT5 exists; the official Linux and macOS packages are Wine wrappers |
| Disabling LiveUpdate | MetaQuotes: "This system can not be deactivated" |

## Combinations

1. **A + C + F (or E): recommended.** A fully config-driven, headless
   terminal: no Xvfb and no UI clicks.
   * **Shutdown:** a clean shutdown could use a new bridge method that calls
     MQL5 `TerminalClose()` (untested).
   * **Debugging:** keep X as an opt-in debug mode for `mt5ctl` and VNC.
2. **B + C + F.** The same result without enabling DLL imports. It means more
   transport code, more CPU at low latency, and native Linux hosts only.
3. **Status quo + E.** The smallest change; `allow-host.sh` stays.
4. **D, later, as an extra.** Possible if signing the terminal in to
   MQL5.community is acceptable.

Prototype sources (scratch, not in the repo): `gbnet.c`/`DllNet.mq5` (A),
`FileBridge.mq5` + Go tailer (B), the null-driver entrypoint (C).
