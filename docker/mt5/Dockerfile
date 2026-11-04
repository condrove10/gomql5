# syntax=docker/dockerfile:1.7
#
# MetaTrader 5 under Wine, headless (Xvfb), with the GoBridge EA compiled and
# auto-attached at start-up. Follows MetaQuotes' own Linux method
# (mt5linux.sh: WineHQ "staging" on Debian trixie).
#
# Build (from the repo root):
#   docker build -f docker/mt5/Dockerfile -t gomql5/mt5 .
# Behind a TLS-intercepting proxy, pass its CA as a build secret:
#   docker build --secret id=ca_cert,src=/path/ca.crt ...
# If Docker Hub rate-limits you: --build-arg BASE_IMAGE=mirror.gcr.io/library/debian:trixie-slim
ARG BASE_IMAGE=debian:trixie-slim
FROM ${BASE_IMAGE}

ARG WINE_BRANCH=staging
ENV DEBIAN_FRONTEND=noninteractive \
    WINEPREFIX=/opt/wine \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    DISPLAY=:99 \
    MT5_DIR="/opt/wine/drive_c/Program Files/MetaTrader 5"

RUN --mount=type=secret,id=ca_cert,required=false \
    set -eux; \
    if [ -f /run/secrets/ca_cert ]; then \
      mkdir -p /usr/local/share/ca-certificates; \
      cp /run/secrets/ca_cert /usr/local/share/ca-certificates/build-extra.crt; \
      # Proxies that only tunnel HTTPS: switch apt to https and trust the CA.
      sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/debian.sources; \
      install -m 0644 /run/secrets/ca_cert /tmp/build-ca.crt; \
      echo 'Acquire::https::CAInfo "/tmp/build-ca.crt";' > /etc/apt/apt.conf.d/99build-ca; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg xvfb xauth x11vnc xdotool imagemagick procps tini; \
    update-ca-certificates; \
    dpkg --add-architecture i386; \
    mkdir -pm755 /etc/apt/keyrings; \
    curl -fsSL https://dl.winehq.org/wine-builds/winehq.key | gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key; \
    curl -fsSL -o /etc/apt/sources.list.d/winehq-trixie.sources \
      https://dl.winehq.org/wine-builds/debian/dists/trixie/winehq-trixie.sources; \
    apt-get update; \
    apt-get install -y --install-recommends winehq-${WINE_BRANCH}; \
    rm -rf /var/lib/apt/lists/* /etc/apt/apt.conf.d/99build-ca /tmp/build-ca.crt; \
    wine --version

COPY docker/mt5/install-mt5.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/install-mt5.sh && install-mt5.sh
COPY docker/mt5/lib.sh /usr/local/lib/gomql5/lib.sh
COPY docker/mt5/entrypoint.sh docker/mt5/allow-host.sh /usr/local/bin/
# Drop the optional build-time proxy CA from the final filesystem.
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/allow-host.sh && \
    if [ -f /usr/local/share/ca-certificates/build-extra.crt ]; then \
      rm -f /usr/local/share/ca-certificates/build-extra.crt && update-ca-certificates --fresh >/dev/null; \
    fi

# EA sources are copied into the terminal and compiled at start-up, so a
# rebuilt image always runs the EA that matches the Go module.
COPY mql5/ /opt/gobridge/mql5/

# Lets scripts/mt5ctl.sh and scripts/e2e.sh find terminal containers.
LABEL org.gomql5.role=mt5
EXPOSE 5900
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s \
  CMD pgrep -f terminal64.exe >/dev/null || exit 1
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
