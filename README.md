# Signal Desktop container

Debian 13 (Trixie) with Signal Desktop installed from Signal's official APT
repository using its published signing key and `signal-desktop.sources` file.
The amd64-only image provides browser access through TigerVNC, Fluxbox,
and noVNC/websockify on port **6080**.

## Run

```bash
docker build --platform linux/amd64 -t flaccid/signal-desktop:latest .
docker volume create signal-profile
docker run --rm --name signal-desktop -p 127.0.0.1:6080:6080 \
  --mount source=signal-profile,target=/home/signal \
  flaccid/signal-desktop:latest
```

Open <http://localhost:6080/> and scan the QR code using Signal on your phone
(Settings → Linked Devices → Link a New Device).

The container runs as **UID/GID 1000**. Bind mounts and Kubernetes PVCs must
be writable by that user. Persist `/home/signal` to retain the linked-device
identity, message database, and configuration across container replacements.
An empty profile starts a new linked-device setup.

### Display settings

The desktop automatically resizes to the browser viewport using TigerVNC and
noVNC's remote-resize support. This changes the actual desktop resolution rather
than stretching a fixed-size image. Fluxbox remains the window manager.

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `SCREEN` | `1920x1080x24` | Initial width × height × colour depth before a browser connects |
| `NOVNC_RESIZE` | `remote` | `remote`: resize desktop to browser; `off`: native pixels/scrolling; `scale`: scale fixed desktop |
| `NOVNC_QUALITY` | `8` | JPEG quality, `0`–`9`; higher uses more bandwidth |
| `NOVNC_COMPRESSION` | `2` | Compression level, `0`–`9`; lower favours less compression work over bandwidth |
| `VNC_FRAMERATE` | `60` | Maximum VNC updates per second, not a guaranteed frame rate |

Quality and compression affect encodings that support those controls. Actual
motion performance depends on available CPU, network bandwidth and the browser.
The desktop is shared: resizing by one connected browser affects other viewers.

For manual control, choose **Scaling mode → None** in noVNC's settings, then
right-click the Fluxbox desktop and choose **Resolution**. The menu lists modes
supported by the running X server, including added 1600×900, 1440p and 4K modes.
Automatic remote resizing can otherwise replace a manually selected resolution
when the browser viewport changes.
`NOVNC_RESIZE=off` makes manual control the default for new connections.

For example, start at 1440p with manual sizing:

```bash
docker run --rm -p 127.0.0.1:6080:6080 \
  -e SCREEN=2560x1440x24 -e NOVNC_RESIZE=off \
  --mount source=signal-profile,target=/home/signal \
  flaccid/signal-desktop:latest
```

Persisted Fluxbox preferences are retained. The session uses a generated runtime
menu with resolution controls and includes `~/.fluxbox/menu` as **Custom menu**
when that file exists.
The session keeps a black background and suppresses theme wallpaper helpers to
avoid background-update races during live resizing. Other style overrides remain.

`NOVNC_PORT` defaults to `6080`; raw VNC listens on loopback port `5900` only.
Optional `VNC_PASSWORD` enables the noVNC password prompt (traditional VNC
authentication uses at most eight password characters).

For kube-workspaces, use the catalog's `signal-desktop` Image and attach a PVC
at `/home/signal`. The launcher derives the WebSocket URL from the browser's
proxy prefix, so it works behind `/proxy/{namespace}/{name}/` as well as locally.
The HTTP endpoint relies on the authenticated workspace proxy; for standalone
use, keep the published port on localhost or put it behind an authenticated TLS
reverse proxy. Electron runs with `--no-sandbox` for container compatibility and
`--password-store=basic` because there is no desktop keyring. Protect the profile
volume accordingly. This image streams the GUI; it does not provide microphone,
camera, or browser audio forwarding for calls.

## Publishing

GitHub Actions follows `flaccid/container-debian-desktop`: build locally in CI,
run the smoke test, then publish to Docker Hub using repository secrets
`DOCKER_USERNAME` and `DOCKER_PASSWORD`.

- Pushes to `main`: `flaccid/signal-desktop:main`, `:latest`, and `:sha-…`.
- Tags matching `v*`: version tag and SHA tag.
- Pull requests: build and smoke-test without publishing.

Rebuild to install current stable Signal packages from APT. Run locally:

```bash
bash tests/smoke-test.sh flaccid/signal-desktop:latest
```
