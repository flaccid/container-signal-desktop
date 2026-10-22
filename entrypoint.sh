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
# The X server supplies a black background. Avoid background-helper races when
# several resize events arrive together, and preserve other Fluxbox preferences.
if [[ ! -e "$HOME/.fluxbox/init" ]]; then
    printf 'session.screen0.rootCommand: /bin/true\n' > "$HOME/.fluxbox/init"
fi
screen="${SCREEN:-1920x1080x24}"
if [[ ! "$screen" =~ ^([1-9][0-9]*)x([1-9][0-9]*)x(16|24|32)$ ]]; then
    printf 'Invalid SCREEN: %s (expected WIDTHxHEIGHTxDEPTH)\n' "$screen" >&2
    exit 1
fi
geometry="${BASH_REMATCH[1]}x${BASH_REMATCH[2]}"
depth="${BASH_REMATCH[3]}"
vnc_args=(-SecurityTypes None)
if [[ -n "${VNC_PASSWORD:-}" ]]; then
    (umask 077; printf '%s\n' "$VNC_PASSWORD" | tigervncpasswd -f > "$XDG_RUNTIME_DIR/vnc.pass")
    vnc_args=(-SecurityTypes VncAuth -PasswordFile "$XDG_RUNTIME_DIR/vnc.pass")
fi
# Integrated X/VNC server supports RandR and noVNC's SetDesktopSize requests.
# Raw RFB remains loopback-only; websockify is the public endpoint.
Xtigervnc "$DISPLAY" -geometry "$geometry" -depth "$depth" \
    -localhost -rfbport "${VNC_PORT:-5900}" -AlwaysShared \
    -AcceptSetDesktopSize -FrameRate "${VNC_FRAMERATE:-60}" \
    -br -nolisten tcp -noreset "${vnc_args[@]}" &
pids+=("$!")
for _ in {1..50}; do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then break; fi
    kill -0 "${pids[0]}"
    sleep 0.2
done
xdpyinfo -display "$DISPLAY" >/dev/null
# TigerVNC's built-in modes stop around 1080p unless a larger initial geometry
# is requested. Register useful higher-resolution modes for the manual menu too.
declare -A available_modes=()
output=""
while read -r name state rest; do
    if [[ "$state" == connected ]]; then output="$name"; fi
    if [[ "$name" =~ ^[0-9]+x[0-9]+$ ]]; then available_modes["$name"]=1; fi
done < <(xrandr --query)
for mode in 1600x900 2560x1440 3840x2160; do
    if [[ -z "${available_modes[$mode]:-}" ]]; then
        while read -r -a modeline; do
            if [[ "${modeline[0]:-}" == Modeline ]]; then
                xrandr --newmode "$mode" "${modeline[@]:2}"
                xrandr --addmode "$output" "$mode"
            fi
        done < <(cvt "${mode%x*}" "${mode#*x}" 60)
    fi
done
# Build a resolution menu from modes actually offered by this X server.
# A runtime rc keeps user preferences while always exposing the managed menu.
menu="$XDG_RUNTIME_DIR/fluxbox-menu"
{
    printf '[begin] (Signal Desktop)\n[submenu] (Resolution)\n'
    printf '[nop] (Use noVNC Scaling: None for manual resolution)\n'
    while read -r mode rest; do
        if [[ "$mode" =~ ^[0-9]+x[0-9]+$ ]]; then
            printf '[exec] (%s) {xrandr --size %s}\n' "$mode" "$mode"
        fi
    done < <(xrandr --query)
    printf '[end]\n'
    if [[ -f "$HOME/.fluxbox/menu" ]]; then
        printf '[submenu] (Custom menu)\n[include] (%s/.fluxbox/menu)\n[end]\n' "$HOME"
    fi
    printf '[config] (Fluxbox settings)\n[workspaces] (Workspaces)\n'
    printf '[reconfig] (Reload Fluxbox configuration)\n[end]\n'
} > "$menu"
overlay="$HOME/.fluxbox/overlay"
{
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*session\.menuFile: ]]; then
            continue
        elif [[ "$line" =~ ^[[:space:]]*session\.styleOverlay: ]]; then
            read -r key overlay <<< "$line"
            overlay="${overlay/#\~\//$HOME/}"
        elif [[ "$line" =~ ^session\.screen0\.rootCommand:[[:space:]]*/usr/bin/fbsetroot[[:space:]]+-solid[[:space:]]+black[[:space:]]*$ ]]; then
            # Migrate the previous image's generated background command only.
            printf 'session.screen0.rootCommand: /bin/true\n'
        else
            printf '%s\n' "$line"
        fi
    done < "$HOME/.fluxbox/init"
    printf 'session.menuFile: %s\n' "$menu"
    printf 'session.styleOverlay: %s/fluxbox-overlay\n' "$XDG_RUNTIME_DIR"
} > "$XDG_RUNTIME_DIR/fluxbox-init"
# rootCommand alone does not suppress theme-triggered fbsetbg on RandR events.
# Keep the user's other style overrides, but let the X server own the background.
if [[ -f "$overlay" ]]; then
    cp "$overlay" "$XDG_RUNTIME_DIR/fluxbox-overlay"
else
    : > "$XDG_RUNTIME_DIR/fluxbox-overlay"
fi
printf '\nbackground: unset\n' >> "$XDG_RUNTIME_DIR/fluxbox-overlay"

# Serve immutable assets alongside per-session, environment-controlled defaults.
web_root="$XDG_RUNTIME_DIR/novnc"
mkdir -p "$web_root"
ln -sfn /opt/novnc/* "$web_root/"
python3 - "$web_root/desktop-config.json" <<'PY'
import json, os, sys
resize = os.environ.get("NOVNC_RESIZE", "remote")
if resize not in ("off", "scale", "remote"):
    sys.exit("NOVNC_RESIZE must be off, scale or remote")
config = {"resize": resize}
for key, default in (("quality", "8"), ("compression", "2")):
    value = int(os.environ.get("NOVNC_" + key.upper(), default))
    if not 0 <= value <= 9:
        sys.exit("NOVNC_" + key.upper() + " must be between 0 and 9")
    config[key] = str(value)
with open(sys.argv[1], "w") as target:
    json.dump(config, target)
PY
# Keep D-Bus in the foreground so the supervisor owns its lifetime too.
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
dbus-daemon --session --nofork --address="$DBUS_SESSION_BUS_ADDRESS" &
pids+=("$!")
fluxbox -rc "$XDG_RUNTIME_DIR/fluxbox-init" &
pids+=("$!")
# No desktop keyring is present. The persisted profile contains Signal's keys.
signal-desktop --no-sandbox --password-store=basic --disable-dev-shm-usage "$@" &
pids+=("$!")
websockify --web "$web_root" "${NOVNC_PORT:-6080}" "127.0.0.1:${VNC_PORT:-5900}" &
pids+=("$!")
status=0
wait -n "${pids[@]}" || status=$?
# Even a clean app exit ends this desktop session.
exit "$status"
