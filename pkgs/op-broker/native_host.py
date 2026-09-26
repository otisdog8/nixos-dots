"""op-broker native messaging host: runs INSIDE the browser sandbox, started by
the browser for the op-broker extension, and forwards its requests to the
broker socket.

It is a pipe with a size limit: WebExtension native messaging (4-byte
native-endian length + JSON on stdio) on one side, the broker's line protocol
on the other. It keeps nothing: each approved credential passes through once,
from the broker's reply to the extension, and is dropped.

The broker socket is /run/sbx/op/sock inside the sandbox (a bind of the
client's broker socket for containers, the vsock relay's guest end for VMs),
or $OP_BROKER_SOCKET.
"""

import json
import os
import socket
import struct
import sys

DEFAULT_SOCKET = "/run/sbx/op/sock"
MAX_FROM_EXTENSION = 16 * 1024  # a request is a few hundred bytes
MAX_FROM_BROKER = 64 * 1024
MAX_TO_EXTENSION = 1024 * 1024  # the browser's limit for host -> extension
# Covers the broker's dialog (60 s default) plus a queue behind another dialog.
REPLY_TIMEOUT = 300


def read_exact(f, n):
    buf = b""
    while len(buf) < n:
        chunk = f.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def read_message(f):
    hdr = read_exact(f, 4)
    if hdr is None:
        return None
    (n,) = struct.unpack("=I", hdr)
    if n > MAX_FROM_EXTENSION:
        sys.exit("op-broker-native-host: message too large")
    data = read_exact(f, n)
    if data is None:
        return None
    return data


def write_message(f, obj):
    data = json.dumps(obj, ensure_ascii=True, separators=(",", ":")).encode()
    if len(data) > MAX_TO_EXTENSION:
        data = json.dumps({"v": 1, "ok": False, "error": "internal"}).encode()
    f.write(struct.pack("=I", len(data)) + data)
    f.flush()


class Broker:
    def __init__(self, path):
        self.path = path
        self.sock = None
        self.buf = b""

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
        self.buf = b""

    def request(self, line):
        if self.sock is None:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
            s.settimeout(5)
            s.connect(self.path)
            self.sock = s
        self.sock.settimeout(REPLY_TIMEOUT)
        self.sock.sendall(line)
        while b"\n" not in self.buf:
            if len(self.buf) > MAX_FROM_BROKER:
                raise OSError("reply too large")
            chunk = self.sock.recv(65536)
            if not chunk:
                raise OSError("broker closed the connection")
            self.buf += chunk
        reply, _, self.buf = self.buf.partition(b"\n")
        return reply


def error(rid, code):
    out = {"v": 1, "ok": False, "error": code}
    if rid is not None:
        out["id"] = rid
    return out


def main():
    path = os.environ.get("OP_BROKER_SOCKET") or DEFAULT_SOCKET
    broker = Broker(path)
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    while True:
        raw = read_message(stdin)
        if raw is None:
            return
        rid = None
        try:
            msg = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            write_message(stdout, error(None, "bad-request"))
            continue
        if not isinstance(msg, dict):
            write_message(stdout, error(None, "bad-request"))
            continue
        rid = msg.get("id") if type(msg.get("id")) is int else None
        # Re-serialized: the broker sees one well-formed line, whatever the
        # extension sent. The broker does all the validation.
        line = json.dumps(msg, ensure_ascii=True, separators=(",", ":")).encode() + b"\n"
        try:
            reply = broker.request(line)
            obj = json.loads(reply)
            if not isinstance(obj, dict):
                raise ValueError("reply is not an object")
        except (OSError, ValueError, UnicodeDecodeError):
            broker.close()
            write_message(stdout, error(rid, "unavailable"))
            continue
        finally:
            del line
        write_message(stdout, obj)
        del obj, reply


if __name__ == "__main__":
    main()
