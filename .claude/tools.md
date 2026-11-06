# Tools

| Tool | Method | Version | Reason |
|---|---|---|---|
| gomql5/novnc:local | Local image, Debian packages | noVNC 1:1.6.0-2, websockify 0.12.0 | Browser access to the terminal |
| gomql5/netcap:local | Local image, Debian package | tcpdump, trixie | Recording requested by the user |
| gopls | Found on host, not installed here | v0.23.0 | Go structure queries |

Missing: tree-sitter, shellcheck, a shell language server. Not installed in AFK mode: `git grep` on given paths is used for shell and MQL5.
