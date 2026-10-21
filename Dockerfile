# Signal Desktop in a container, served to the browser through noVNC.
#
# Signal Desktop is an Electron app with no official container image, so the
# workspace image is assembled here from a Debian base following Signal's own
# "Linux (Debian-based)" install instructions, plus the X/VNC stack the
# kube-workspaces proxy needs to reach a GUI application.
#
# The result is a single-port container: websockify serves the noVNC client and
# the RFB websocket on one port, which the controller maps to Service port 80.
FROM debian:trixie-slim

# Signal Desktop (8.x) is an Electron application; keep the sandbox off. The
# Chromium setuid sandbox cannot be used inside a container without extra
# privileges, and Electron's namespace sandbox needs user namespaces that are
# not available on every cluster node.
#
# DISPLAY/XDG_RUNTIME_DIR are read by the Electron runtime and the entrypoint.
ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:0 \
    HOME=/home/signal \
    XDG_RUNTIME_DIR=/tmp/.runtime \
    SCREEN=1280x800x24 \
    VNC_PORT=5900 \
    NOVNC_PORT=6080

# Signal's official apt repository, following Signal's Debian install
# instructions: install the public signing key as a keyring, drop the sources
# file into /etc/apt/sources.list.d, then apt install signal-desktop.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    curl -fsSL https://updates.signal.org/desktop/apt/keys.asc \
        | gpg --dearmor -o /usr/share/keyrings/signal-desktop-keyring.gpg; \
    curl -fsSL https://updates.signal.org/static/desktop/apt/signal-desktop.sources \
        -o /etc/apt/sources.list.d/signal-desktop.sources; \
    apt-get update; \
    apt-get install -y --no-install-recommends signal-desktop; \
    apt-get purge -y --auto-remove gnupg; \
    rm -rf /var/lib/apt/lists/*

# X server, VNC server and the noVNC web client.
#
# The Electron runtime libraries are listed explicitly: Signal's .deb only
# declares a handful of them, but the Chromium sandbox helpers it ships need
# the full set to load libgbm, GTK and the audio stack.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        dbus-x11 \
        feh \
        fluxbox \
        fonts-liberation \
        fonts-noto-color-emoji \
        libasound2t64 \
        libatk-bridge2.0-0 \
        libatk1.0-0 \
        libatspi2.0-0 \
        libcairo2 \
        libcups2 \
        libdrm2 \
        libgbm1 \
        libgtk-3-0 \
        libnotify4 \
        libnss3 \
        libpango-1.0-0 \
        libpulse0 \
        libx11-xcb1 \
        libxcomposite1 \
        libxdamage1 \
        libxfixes3 \
        libxkbcommon0 \
        libxrandr2 \
        libxss1 \
        libxtst6 \
        novnc \
        tini \
        websockify \
        x11-utils \
        x11vnc \
        xauth \
        xvfb; \
    rm -rf /var/lib/apt/lists/*

# The unprivileged account Signal Desktop runs as. UID 1000 matches the
# catalog convention. Mounted volumes must be writable by UID 1000.
RUN set -eux; \
    useradd --create-home --uid 1000 --shell /bin/bash signal; \
    mkdir -p /var/run/dbus /tmp/.runtime /tmp/.X11-unix; \
    chmod 1777 /tmp/.X11-unix; \
    chown signal:signal /tmp/.runtime; \
    chmod 700 /tmp/.runtime

# Serve the noVNC client from a private copy of the packaged web root so the
# launcher page (which rewrites the websocket path for the reverse proxy) can
# replace the packaged index without touching a dpkg-managed file.
RUN cp -a /usr/share/novnc /opt/novnc
COPY novnc-index.html /opt/novnc/index.html

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

EXPOSE 6080

USER 1000:1000
WORKDIR /home/signal
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
