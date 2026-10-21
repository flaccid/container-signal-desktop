#!/bin/bash
set -euo pipefail
image="${1:-flaccid/signal-desktop:latest}"
container=$(docker run -d "$image")
cleanup() {
    status=$?
    if ((status)); then docker logs "$container"; fi
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
for path in ("/", "/vnc.html", "/app/ui.js", "/core/rfb.js"):
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
for (const base of ["/", "/proxy/example/signal/"]) {
  let target;
  vm.runInNewContext(script, { URLSearchParams, window: { location: {
    pathname: base, replace: value => { target = value; }
  } } });
  const redirected = new URL(target, "https://example.test" + base);
  const wsPath = redirected.searchParams.get("path");
  assert.equal("/" + wsPath, base + "websockify");
  assert.equal(redirected.pathname, base + "vnc.html");
}
console.log("Local and workspace-prefixed launcher URLs passed");
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
