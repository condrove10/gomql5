# MetaTrader 5 on Linux and in Docker (state as of November 2026)

## Verified in session 1 (2026-11-04)

These results are from building and running `docker/mt5` in a Linux sandbox.
No broker account was used.

* **Install:** WineHQ **11.21 staging** on `debian:trixie-slim` installs MT5
  headless. `mt5setup.exe /auto` under Xvfb takes about 1 minute, giving
  terminal build 6295/6296. The image was about 7.3 GB; see "Image size"
  below for the cuts that bring it to about 4.4 GB.
  * Wine's Mono/Gecko prompt hangs `wineboot` under Xvfb (it fails after 300 s
    with `could not load kernel32.dll`). Setting
    `WINEDLLOVERRIDES="mscoree,mshtml="` during `wineboot` avoids it.
* **EA compile:** `MetaEditor64.exe /portable /compile:MQL5\Experts\GoBridge\GoBridge.mq5 /log:C:\x.log`
  compiles GoBridge with **0 errors, 0 warnings**. Two details matter:
  * Run it with the install folder as the current directory and use a
    relative path.
  * An explicit `/log:<file>` is needed to get a log at all.
* **Start-up config:** `terminal64.exe /portable /config:C:\gobridge\gobridge.ini`
  works. The path **must not contain spaces**: with `C:\Program Files\…` the
  terminal logs `cannot load config "…""`.
  * `[StartUp] Expert=GoBridge\GoBridge`, `ExpertParameters=GoBridge.set`,
    `Symbol`/`Period` attach the EA.
  * `[Experts] AllowLiveTrading=1` and `WebRequest=1` tick the matching
    checkboxes.
* **`.set` file:** UTF-16LE with a BOM and CRLF line endings is read
  (`3 inputs read …`). The last line also needs CRLF, otherwise the trailing
  `\r` ends up in the value.
* **The allowed-URL list** gates `SocketConnect`; without it you get error 4014.
  * It's stored **encrypted** in `config/settings.ini`, so nothing can write
    it as a file.
  * It **rejects single-label names** (`app`, and also `http://app`).
    IPv4 addresses and `localhost` are accepted.
  * In testing it did not reliably survive a restart.

  So the entrypoint does three things on every start:
  1. Resolves `GOBRIDGE_HOST` to an IP.
  2. Adds that IP through the Options dialog using `xdotool` (`allow-host.sh`).
  3. Watches `/proc/net/tcp` for the EA's connection and retries if it doesn't
     appear.
* **End-to-end** with the GoBridge EA, both in host-network mode and with
  `docker compose` (service name `app`): the hello is accepted, then
  `terminal_info`, `account_info`, `symbol_info`, `copy_rates_from_pos` and
  the tick subscription all work. Without a login the terminal shows bundled
  demo history.
* **Graceful stop:** the terminal saves settings only on a clean exit. With
  no window manager, the entrypoint's SIGTERM handler presses Escape (to
  dismiss e.g. the LiveUpdate "Restart" modal), focuses the main window and
  sends Alt+F4. Use `docker stop -t 30`.
* **New in 2026 builds** (observed, not used): the Options dialog has *AI
  Assistant* and *MCP* tabs.
  * The terminal logs `MCP started on 127.0.0.1:22346`.
  * `config/assistant.ini` lists MCP endpoints for MetaTrader
    (`http://127.0.0.1:22346/mcp`) and MetaEditor (`:22345`), each with an
    API key.

  That could become an alternative data path; it's unexplored (see the
  roadmap).

## Facts checked at the source

* **MetaQuotes doesn't ship a native Linux terminal.** Their official route is
  `mt5linux.sh` (`download.mql5.com/.../mt5linux.sh`): WineHQ **staging**
  (Debian 12/13, Ubuntu up to 25.10, Fedora 41–43), then `mt5setup.exe`, the
  WebView2 runtime and Wine set to Windows 11 mode.
* **The `MetaTrader5` Python package (v5.0.6231) only runs on Windows**
  (`win_amd64` wheels). Its compiled core opens the named pipe
  `\\.\pipe\MT5.Terminal.<hash>` and starts `terminal64.exe` itself.
* **MQL5 sockets can only connect out** (`SocketCreate`, `SocketConnect`,
  `SocketTls*`; no listen). The allowed-host list "cannot be added
  programmatically".
* The documented start-up config keys are `[Common]`, `[Experts]` and
  `[StartUp]` (see the terminal help, "Platform Start").

## Image size (session 2026-11-05)

`docker image inspect -f '{{.Size}}'`: **7,278,172,227 → 4,364,788,631 bytes**
(7.28 → 4.36 GB). Per layer (`docker history`):

| Cut | Layer before → after | Saved |
| --- | --- | --- |
| `wineboot` copies every builtin DLL into `system32` / `syswow64`, byte-identical to `/opt/wine-staging/lib/wine/{x86_64,i386}-windows`. `install-mt5.sh` replaces each copy that `cmp`s equal with a symlink (1,480 files), in the same RUN layer. `drive_c/windows`: 1.6 GB → 130 MB | install layer 2.2 GB → 511 MB | ~1.6 GB |
| Delete `AppData/Roaming/MetaQuotes/WebInstall` (the web installer's cache) and temp files | (same layer) | ~109 MB |
| `winehq-staging` with `--no-install-recommends`, plus the Recommends Wine needs here named explicitly (gnutls, freetype, fontconfig, dbus, the X11 extension libs; amd64 and the i386 ones for gnutls/fonts/X11). Drops GTK 3, Vulkan/VA drivers, CUPS, SDL, ODBC, GLU, poppler-data | apt layer 3.13 GB → 2.67 GB | ~460 MB |

Kept on purpose: i386 Wine (dropping it is a separate, riskier step),
`Bases/Default/History` (the no-account e2e reads its cached quote),
ImageMagick/x11vnc/xdotool/Xvfb (tooling). What remains is mostly
`wine-staging-{amd64,i386}` (1.7 GB) and their hard Depends (LLVM via
Mesa, libavcodec, GStreamer).

Verified on the slim image: `scripts/e2e.sh` PASS, `scripts/goldrec-e2e.sh
--broker-symbol EURUSD --min-ticks 1 --restart` PASS, GoBridge compiles with
0 errors, 0 warnings, and screenshots render fonts and charts normally.
`E2E_IMAGE=<tag>` makes both scripts build/run another tag than
`gomql5/mt5:local`.

## Community images seen in a 2026 search

I haven't audited any of these.

| project | approach |
|---|---|
| blunan/metatrader-docker | WineHQ staging on linuxserver.io Selkies (Debian 13), browser desktop |
| marketcalls/meta-docker | headless Debian + Wine with REST/WebSocket/gRPC on top |
| eden7tech/mt5linux | compose setup, Wine prefix on the host, noVNC, RPyC to Windows-Python `MetaTrader5` |
| vfeitoza/metatrader5-docker | Wine + RDP; recommends `--shm-size=512m` |
| mt5linux (PyPI) | Python RPyC bridge to a Wine-hosted Windows Python |
| ejtraderLabs/ejtraderMT-Docker | 2023-era Alpine/VNC + ZeroMQ; likely stale |

## Not verified yet

* **Broker login** through `MT5_LOGIN`/`MT5_PASSWORD`/`MT5_SERVER`, and
  trading. The password is written to `C:\gobridge\gobridge.ini` in the
  container, outside the volume, but the terminal may remember the account
  in the volume (`KeepPrivate=1`).
* **`allow-host.sh` coordinates** were recorded against build 6295/6296 on a
  1280×1024 screen. A UI change in a future build would break them. The
  retry loop then gives up after 10 attempts and logs it; fall back to VNC.
* **Wine `staging` keeps moving.** For reproducible images, pin it
  (`WINE_BRANCH`, or an exact version in the Dockerfile).
