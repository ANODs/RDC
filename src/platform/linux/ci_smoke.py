#!/usr/bin/env python3
"""Smoke test of the Linux host, run by .github/workflows/linux.yml under Xvfb.

  ci_smoke.py <host log> [<out dir>] [--window]

--window: the host shows its GTK window on the same screen, which may redraw on its own (a hover,
a status line), so a still screen there is only reported, not required.

Reads the code and port from the host's log, connects as a viewer does over the local network
(a WebSocket on /ws, then {"t":"hello","code":…} — see src/core/proto.zig and wsLink/connect in
web/viewer.js), and checks: the host answers "ok"; a JPEG frame arrives; a still screen sends
nothing; a mouse move from the viewer moves the X pointer (xdotool) and brings a fresh frame,
since the cursor is drawn into the picture. Only the standard library: raw sockets, no packages.
"""
import base64
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time


def fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


def wait_code(log_path, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(log_path, errors="replace") as f:
                text = f.read()
        except FileNotFoundError:
            text = ""
        m = re.search(r"link http://[^/\s]+:(\d+)/#(\d{9})", text)
        if m:
            return int(m.group(1)), m.group(2)
        time.sleep(0.2)
    fail("no code in the host's log")


class WebSocket:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (port, key)
        )
        self.sock.sendall(req.encode())
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                fail("the host closed the connection during the handshake")
            self.buf += chunk
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            fail("no WebSocket upgrade: %r" % head[:80])

    def send(self, opcode, payload):
        # Client frames are masked (RFC 6455, 5.3).
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            hdr = struct.pack("!BB", 0x80 | opcode, 0x80 | n)
        elif n < 65536:
            hdr = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, n)
        else:
            hdr = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, n)
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(hdr + mask + body)

    def send_json(self, obj):
        # Compact, as browsers send it: the host reads JSON without spaces between tokens.
        self.send(1, json.dumps(obj, separators=(",", ":")).encode())

    def _need(self, n, deadline):
        while len(self.buf) < n:
            left = deadline - time.time()
            if left <= 0:
                return False
            self.sock.settimeout(left)
            try:
                chunk = self.sock.recv(1 << 16)
            except socket.timeout:
                return False
            if not chunk:
                fail("the host closed the connection")
            self.buf += chunk
        return True

    def recv(self, timeout):
        """(opcode, payload) of the next message, or None after timeout seconds."""
        deadline = time.time() + timeout
        if not self._need(2, deadline):
            return None
        b0, b1 = self.buf[0], self.buf[1]
        n, off = b1 & 0x7F, 2
        if n == 126:
            if not self._need(4, deadline):
                return None
            n, off = struct.unpack("!H", self.buf[2:4])[0], 4
        elif n == 127:
            if not self._need(10, deadline):
                return None
            n, off = struct.unpack("!Q", self.buf[2:10])[0], 10
        # A big frame may take a moment longer than the poll.
        if not self._need(off + n, max(deadline, time.time() + 10)):
            fail("a message from the host was cut short")
        payload = self.buf[off : off + n]
        self.buf = self.buf[off + n :]
        return b0 & 0x0F, payload


def xdotool(*args):
    return subprocess.run(["xdotool", *args], check=True, capture_output=True, text=True).stdout


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    window = "--window" in sys.argv[1:]
    if not args:
        fail("usage: ci_smoke.py <host log> [<out dir>] [--window]")
    out_dir = args[1] if len(args) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    port, code = wait_code(args[0])
    print("host on port %d, code %s" % (port, code))

    ws = WebSocket(port)
    ws.send_json({"t": "hello", "code": code, "h264": False, "agent": "ci_smoke.py"})
    ok, frames, last_ping = None, [], 0.0

    def pump(seconds):
        """Reads messages for a while, pinging as the viewer does; returns the frames that came."""
        nonlocal ok, last_ping
        got = []
        deadline = time.time() + seconds
        while time.time() < deadline:
            if time.time() - last_ping > 1:
                ws.send_json({"t": "ping", "ts": int(time.time() * 1000)})
                last_ping = time.time()
            m = ws.recv(min(0.25, max(0.01, deadline - time.time())))
            if m is None:
                continue
            opcode, payload = m
            if opcode == 1:
                msg = json.loads(payload)
                if msg.get("t") == "ok":
                    ok = msg
                    print("ok:", payload.decode())
                elif msg.get("t") == "err":
                    fail("the host refused: %s" % msg.get("msg"))
                elif msg.get("t") != "pong":
                    print("text:", payload.decode()[:200])
            elif opcode == 2:
                got.append(payload)
            elif opcode == 8:
                fail("the host closed the session: %r" % payload[2:])
        return got

    # 1. "ok", then a JPEG frame.
    deadline = time.time() + 15
    while time.time() < deadline and not (ok and frames):
        frames += pump(0.5)
    if not ok:
        fail("no ok from the host")
    if ok.get("os") != "linux":
        fail("the host says it runs %r" % ok.get("os"))
    if not frames:
        fail("no frame in 15 s")
    f = frames[0]
    if f[0] != 2 or f[10:12] != b"\xff\xd8" or f[-2:] != b"\xff\xd9":
        fail("the first frame is not a JPEG: kind %d, %r…%r" % (f[0], f[10:14], f[-2:]))
    with open(os.path.join(out_dir, "frame.jpg"), "wb") as out:
        out.write(f[10:])
    print("frame: JPEG, %d bytes (saved as %s)" % (len(f) - 10, os.path.join(out_dir, "frame.jpg")))

    # 2. A still screen sends nothing.
    pump(1.5)
    still = pump(3)
    if still and not window:
        fail("%d frames came from a still screen in 3 s" % len(still))
    print("still screen: %d frames in 3 s" % len(still))

    # 3. A mouse move from the viewer moves the X pointer; the cursor in the picture brings a frame.
    width, height = (int(v) for v in xdotool("getdisplaygeometry").split())
    nx, ny = 0.25, 0.75
    ws.send(2, struct.pack("<Bff", 1, nx, ny))
    time.sleep(0.5)
    loc = dict(kv.split("=", 1) for kv in xdotool("getmouselocation", "--shell").split())
    want_x, want_y = round(nx * (width - 1)), round(ny * (height - 1))
    x, y = int(loc["X"]), int(loc["Y"])
    if abs(x - want_x) > 1 or abs(y - want_y) > 1:
        fail("the pointer is at %d,%d, expected %d,%d" % (x, y, want_x, want_y))
    print("mouse: the pointer moved to %d,%d" % (x, y))
    moved = pump(3)
    if not moved:
        fail("no frame after the pointer moved")
    with open(os.path.join(out_dir, "frame-after-move.jpg"), "wb") as out:
        out.write(moved[-1][10:])
    print("frame after the move: %d" % len(moved))

    ws.send(8, struct.pack("!H", 1000))
    print("PASS")


if __name__ == "__main__":
    main()
