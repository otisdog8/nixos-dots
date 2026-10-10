"""sbx-clip-guest against real data-control clients (wl-copy / wl-paste, when
on PATH or in WL_CLIPBOARD), a stand-in display proxy and a stand-in broker."""

import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "clip-guest.py")
WL = os.environ.get("WL_CLIPBOARD") or (os.path.dirname(shutil.which("wl-copy")) if shutil.which("wl-copy") else None)


def wl_string(s):
    b = s.encode() + b"\0"
    return struct.pack("<I", len(b)) + b + b"\0" * (-len(b) % 4)


def wl_message(obj, opcode, args=b""):
    return struct.pack("<II", obj, ((8 + len(args)) << 16) | opcode) + args


class FakeDisplay(threading.Thread):
    """A compositor with one global (wl_seat) that answers sync and nothing
    else, and records the ids of every object a request was sent to."""

    def __init__(self, path):
        super().__init__(daemon=True)
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(8)
        self.seen = []  # (object, opcode) of every request

    def run(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self.client, args=(c,), daemon=True).start()

    def client(self, c):
        buf = b""
        while True:
            try:
                data = c.recv(65536)
            except OSError:
                return
            if not data:
                return
            buf += data
            while len(buf) >= 8:
                obj, word = struct.unpack_from("<II", buf)
                size, opcode = word >> 16, word & 0xFFFF
                if len(buf) < size:
                    break
                body, buf = buf[8:size], buf[size:]
                self.seen.append((obj, opcode))
                if obj == 1 and opcode == 0:  # sync
                    (cb,) = struct.unpack_from("<I", body)
                    c.sendall(wl_message(cb, 0, struct.pack("<I", 0)) + wl_message(1, 1, struct.pack("<I", cb)))
                elif obj == 1 and opcode == 1:  # get_registry
                    (reg,) = struct.unpack_from("<I", body)
                    c.sendall(wl_message(reg, 0, struct.pack("<I", 1) + wl_string("wl_seat") + struct.pack("<I", 5)))


class FakeBroker(threading.Thread):
    def __init__(self, path):
        super().__init__(daemon=True)
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(8)
        self.requests = []

    def run(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            line = b""
            while not line.endswith(b"\n"):
                chunk = c.recv(65536)
                if not chunk:
                    break
                line += chunk
            self.requests.append(json.loads(line))
            c.sendall(b'{"type": "granted"}\n')
            c.close()

    def wait(self, n, timeout=5):
        end = time.monotonic() + timeout
        while len(self.requests) < n and time.monotonic() < end:
            time.sleep(0.02)
        return self.requests


@unittest.skipUnless(WL, "no wl-clipboard")
class ClipGuest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.display = FakeDisplay(os.path.join(self.dir, "up"))
        self.display.start()
        self.broker = FakeBroker(os.path.join(self.dir, "broker"))
        self.broker.start()
        self.listen = os.path.join(self.dir, "wl")
        self.proc = subprocess.Popen(
            [sys.executable, "-IS", SCRIPT, "--listen", self.listen, "--upstream", self.display.srv.getsockname(), "--broker", self.broker.srv.getsockname()],
            stderr=subprocess.PIPE,
        )
        self.addCleanup(self.stop)
        end = time.monotonic() + 5
        while not os.path.exists(self.listen) and time.monotonic() < end:
            time.sleep(0.02)
        self.env = dict(os.environ, WAYLAND_DISPLAY=self.listen, XDG_RUNTIME_DIR=self.dir)

    def stop(self):
        self.proc.kill()
        self.proc.stderr.close()
        self.proc.wait()

    def run_wl(self, *argv, input=None, timeout=10):
        return subprocess.run([os.path.join(WL, argv[0]), *argv[1:]], env=self.env, input=input, capture_output=True, timeout=timeout)

    def test_copy_reaches_the_broker_and_reads_back(self):
        r = self.run_wl("wl-copy", "--foreground", "hunter2")
        self.assertEqual(r.returncode, 0, r.stderr)  # cancelled once the host has it
        reqs = self.broker.wait(1)
        self.assertEqual(reqs, [{"op": "clipboard", "data": base64.b64encode(b"hunter2").decode(), "sensitive": False}])
        # Reading offers what this VM copied, and nothing went upstream but the
        # registry, the seat and syncs.
        r = self.run_wl("wl-paste", "--no-newline")
        self.assertEqual((r.returncode, r.stdout), (0, b"hunter2"), r.stderr)
        self.assertTrue(all(obj <= 3 or op == 0 for obj, op in self.display.seen), self.display.seen)

    def test_sensitive_and_clear(self):
        r = self.run_wl("wl-copy", "--foreground", "--sensitive", "s3cret")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.broker.wait(1)[0]["sensitive"], True)
        r = self.run_wl("wl-copy", "--clear")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.broker.wait(2)[1], {"op": "clipboard", "clear": True})
        r = self.run_wl("wl-paste", "--no-newline")
        self.assertNotEqual(r.returncode, 0)  # nothing to paste

    def test_not_text(self):
        r = self.run_wl("wl-copy", "--foreground", "--type", "image/png", input=b"\x89PNG")
        self.assertEqual(r.returncode, 0, r.stderr)
        time.sleep(0.3)
        self.assertEqual(self.broker.requests, [])


if __name__ == "__main__":
    unittest.main()
