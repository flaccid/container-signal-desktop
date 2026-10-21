# Signal Desktop container

Debian 13 (Trixie) with Signal Desktop installed from Signal's official APT
repository using its published signing key and `signal-desktop.sources` file.
The amd64-only image provides browser access through Xvfb, Fluxbox, x11vnc,
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

`SCREEN` defaults to `1280x800x24`; noVNC scales the fixed display to the browser.
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
