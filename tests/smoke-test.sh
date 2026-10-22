#!/bin/bash
set -euo pipefail
image="${1:-flaccid/signal-desktop:latest}"
container=$(docker run -d "$image")
configured_container=""
cleanup() {
    status=$?
    if ((status)); then docker logs "$container"; fi
    if [[ -n "$configured_container" ]]; then
        if ((status)); then docker logs "$configured_container"; fi
        docker rm -f "$configured_container" >/dev/null
    fi
    docker rm -f "$container" >/dev/null
}
trap cleanup EXIT
for _ in {1..60}; do
    if docker exec "$container" curl -fsS http://127.0.0.1:6080/vnc.html >/dev/null 2>&1; then break; fi
    sleep 1
done
# Verify a real RFB handshake over WebSocket, not merely an open HTTP port.
docker exec "$container" python3 -c '
import base64, os, socket, urllib.request
assert os.getuid() == 1000
for path in ("/", "/vnc.html", "/app/ui.js", "/core/rfb.js", "/desktop-config.json"):
    assert urllib.request.urlopen("http://127.0.0.1:6080" + path).status == 200
s = socket.create_connection(("127.0.0.1", 6080), timeout=10)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET /websockify HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Protocol: binary\r\n\r\n").encode())
data = b""
while b"RFB 003.008" not in data:
    part = s.recv(4096)
    assert part, data
    data += part
assert b"101 Switching Protocols" in data
print("HTTP assets and WebSocket/RFB handshake passed")
'
docker exec "$container" node -e '
const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");
const script = fs.readFileSync("/opt/novnc/index.html", "utf8").match(/<script>([\s\S]*?)<\/script>/)[1];
(async () => {
const config = await (await fetch("http://127.0.0.1:6080/desktop-config.json")).json();
assert.equal(config.resize, "remote");
for (const base of ["/", "/proxy/example/signal/"]) {
  let target;
  await vm.runInNewContext(script, { URLSearchParams,
    fetch: async () => ({ ok: true, json: async () => config }),
    window: { location: {
    pathname: base, replace: value => { target = value; }
  } } });
  const redirected = new URL(target, "https://example.test" + base);
  const wsPath = redirected.searchParams.get("path");
  assert.equal("/" + wsPath, base + "websockify");
  assert.equal(redirected.pathname, base + "vnc.html");
  assert.equal(redirected.searchParams.get("resize"), "remote");
  assert.equal(redirected.searchParams.get("quality"), config.quality);
  assert.equal(redirected.searchParams.get("compression"), config.compression);
}
console.log("Local and workspace-prefixed launcher URLs passed");
})().catch(error => { console.error(error); process.exit(1); });
'
# Exercise the same RFB SetDesktopSize request used by noVNC remote resizing.
docker exec "$container" python3 -c '
import socket, struct, subprocess, time
s = socket.create_connection(("127.0.0.1", 5900), timeout=10)
def receive(size):
    data = b""
    while len(data) < size:
        chunk = s.recv(size - len(data))
        assert chunk, "Unexpected RFB disconnect"
        data += chunk
    return data
assert receive(12) == b"RFB 003.008\n"
s.sendall(b"RFB 003.008\n")
assert 1 in receive(receive(1)[0])
s.sendall(b"\x01")
assert receive(4) == b"\x00" * 4
s.sendall(b"\x01")
header = receive(24)
assert struct.unpack("!HH", header[:4]) == (1920, 1080)
receive(struct.unpack("!I", header[20:])[0])
s.sendall(struct.pack("!BBHi", 2, 0, 1, -308))
for width, height in ((1600, 900), (1920, 1080)):
    s.sendall(struct.pack("!BBHHBBIHHHHI", 251, 0, width, height, 1, 0,
                          0, 0, 0, width, height, 0))
    for _ in range(50):
        info = subprocess.check_output(["xdpyinfo"], text=True)
        if f"dimensions:    {width}x{height} pixels" in info:
            break
        time.sleep(0.1)
    else:
        raise AssertionError(f"RFB desktop resize failed: {width}x{height}")
s.close()
print("RFB remote desktop resizing passed")
'
# Manual Fluxbox menu actions use RandR; verify both changes and menu wiring.
docker exec "$container" bash -ec '
    grep -q "xrandr --size 1280x800" "$XDG_RUNTIME_DIR/fluxbox-menu"
    grep -q "session.menuFile:" "$XDG_RUNTIME_DIR/fluxbox-init"
    xrandr --size 1280x800
    xdpyinfo | grep -q "dimensions:    1280x800 pixels"
    xrandr --size 2560x1440
    xdpyinfo | grep -q "dimensions:    2560x1440 pixels"
    xrandr --query | grep -q "VNC-0 connected 2560x1440"
    xrandr --size 1920x1080
'
# Check environment overrides, persisted preferences, and migrated VNC auth.
configured_container=$(docker run -d \
    -e SCREEN=2560x1440x24 -e NOVNC_RESIZE=off \
    -e NOVNC_QUALITY=9 -e NOVNC_COMPRESSION=4 -e VNC_FRAMERATE=30 \
    -e VNC_PASSWORD=smoketest --entrypoint /bin/bash "$image" -c '
        mkdir -p "$HOME/.fluxbox"
        printf "session.screen0.workspaces: 3\nsession.screen0.rootCommand: /usr/bin/fbsetroot -solid black\n" > "$HOME/.fluxbox/init"
        printf "[begin] (Custom)\n[nop] (Saved menu)\n[end]\n" > "$HOME/.fluxbox/menu"
        exec /usr/local/bin/entrypoint.sh
    ')
for _ in {1..60}; do
    if docker exec "$configured_container" curl -fsS http://127.0.0.1:6080/desktop-config.json >/dev/null 2>&1; then break; fi
    sleep 1
done
docker exec "$configured_container" python3 -c '
import json, os, re, socket, stat, struct, urllib.request
from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES
from cryptography.hazmat.primitives.ciphers import Cipher, modes
config = json.load(urllib.request.urlopen("http://127.0.0.1:6080/desktop-config.json"))
assert config == {"resize": "off", "quality": "9", "compression": "4"}, config
runtime = os.environ["XDG_RUNTIME_DIR"]
with open(os.path.expanduser("~/.fluxbox/init")) as source:
    assert source.read() == ("session.screen0.workspaces: 3\n"
                             "session.screen0.rootCommand: /usr/bin/fbsetroot -solid black\n")
with open(runtime + "/fluxbox-init") as source:
    rc = source.read()
    assert re.search(r"session.screen0.workspaces:\s+3", rc)
    assert re.search(r"session.screen0.rootCommand:\s+/bin/true", rc)
with open(runtime + "/fluxbox-menu") as source:
    assert "[include] (/home/signal/.fluxbox/menu)" in source.read()
assert stat.S_IMODE(os.stat(runtime + "/vnc.pass").st_mode) == 0o600
s = socket.create_connection(("127.0.0.1", 5900), timeout=10)
def receive(size):
    data = b""
    while len(data) < size:
        chunk = s.recv(size - len(data))
        assert chunk, "Unexpected RFB disconnect"
        data += chunk
    return data
assert receive(12) == b"RFB 003.008\n"
s.sendall(b"RFB 003.008\n")
assert receive(receive(1)[0]) == b"\x02", "Expected password-only authentication"
s.sendall(b"\x02")
challenge = receive(16)
key = bytes(int(f"{byte:08b}"[::-1], 2) for byte in b"smoketes")
encryptor = Cipher(TripleDES(key * 3), modes.ECB()).encryptor()
s.sendall(encryptor.update(challenge) + encryptor.finalize())
assert receive(4) == b"\x00" * 4, "VNC authentication failed"
s.sendall(b"\x01")
header = receive(24)
assert struct.unpack("!HH", header[:4]) == (2560, 1440)
s.close()
print("Display overrides, persisted Fluxbox settings and VNC authentication passed")
'
# Wait for Electron to map a real application window.
for _ in {1..60}; do
    if docker exec "$container" sh -c 'xwininfo -root -tree | grep -q "\"Signal\""'; then
        docker exec "$container" sh -c '! xwininfo -root -tree | grep -q "\"xmessage\""'
        docker stop -t 15 "$container" >/dev/null
        test "$(docker inspect -f '{{.State.ExitCode}}' "$container")" = 0
        exit 0
    fi
    sleep 1
done
exit 1
