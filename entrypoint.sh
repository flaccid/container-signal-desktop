#!/bin/bash
# Supervise the desktop session; losing any essential process restarts the pod.
set -euo pipefail
export DISPLAY="${DISPLAY:-:0}"
export HOME="${HOME:-/home/signal}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/.runtime}"
pids=()
cleanup() {
    trap - EXIT TERM INT
    if ((${#pids[@]})); then
        kill "${pids[@]}" 2>/dev/null || true
        wait "${pids[@]}" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 0' TERM INT
mkdir -p "$XDG_RUNTIME_DIR" "$HOME/.config" "$HOME/.cache" "$HOME/.fluxbox"
chmod 700 "$XDG_RUNTIME_DIR"
# Override the theme background command to avoid fbsetbg's first-run dialog.
printf 'session.screen0.rootCommand: /usr/bin/fbsetroot -solid black\n' > "$HOME/.fluxbox/init"
Xvfb "$DISPLAY" -screen 0 "${SCREEN:-1280x800x24}" -nolisten tcp -noreset &
pids+=("$!")
for _ in {1..50}; do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then break; fi
    kill -0 "${pids[0]}"
    sleep 0.2
done
xdpyinfo -display "$DISPLAY" >/dev/null
# Keep D-Bus in the foreground so the supervisor owns its lifetime too.
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
dbus-daemon --session --nofork --address="$DBUS_SESSION_BUS_ADDRESS" &
pids+=("$!")
fluxbox &
pids+=("$!")
# No desktop keyring is present. The persisted profile contains Signal's keys.
signal-desktop --no-sandbox --password-store=basic --disable-dev-shm-usage "$@" &
pids+=("$!")
vnc_args=(-nopw)
if [[ -n "${VNC_PASSWORD:-}" ]]; then
    umask 077
    x11vnc -storepasswd "$VNC_PASSWORD" "$XDG_RUNTIME_DIR/vnc.pass"
    vnc_args=(-rfbauth "$XDG_RUNTIME_DIR/vnc.pass")
fi
# Raw RFB is loopback-only. Only the web endpoint listens on the pod network.
x11vnc -display "$DISPLAY" -localhost -rfbport "${VNC_PORT:-5900}" \
    -forever -shared -noxdamage -repeat "${vnc_args[@]}" &
pids+=("$!")
websockify --web /opt/novnc "${NOVNC_PORT:-6080}" "127.0.0.1:${VNC_PORT:-5900}" &
pids+=("$!")
status=0
wait -n "${pids[@]}" || status=$?
# Even a clean app exit ends this desktop session.
exit "$status"
