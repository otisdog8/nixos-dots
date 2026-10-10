"""sbx-clip-guest: data-control copying for an app in a sandbox VM.

Some apps set the clipboard through the data-control protocols
(zwlr_data_control_manager_v1, ext_data_control_manager_v1) instead of
wl_data_device: 1Password does (arboard / wl-clipboard-rs). A sandbox's Wayland
socket has no data-control (it would let the sandbox read everything you copy),
and the guest's display proxy doesn't relay it, so those copies went nowhere.

This sits between the app and the guest's display proxy:

  app ── LISTEN (the app's WAYLAND_DISPLAY) ── sbx-clip-guest ── UPSTREAM (the proxy)

Everything passes through untouched, except that the registry also advertises
the two data-control managers, and what a client does with them is answered
here, never forwarded:

  - set_selection(source): the source's text is read and handed to the host's
    broker (op "clipboard", lib/broker/broker.py), which puts it on the host's
    clipboard. The source is then cancelled: the host serves it from there on.
  - set_selection(null): the broker clears the host's clipboard, if what is on
    it is still what this VM put there.
  - reading: a client is offered only what this VM copied last (so an app that
    checks "is my secret still there" before clearing it gets an answer), never
    the host's clipboard.

So the VM can set the host's clipboard and nothing else: no reading it. Text
only. The primary selection isn't handled.

Wire format: every message is <object:u32> <size:u16 opcode:u16 as one u32>
then arguments; strings are a u32 length (with the NUL) and padded to 4 bytes.
Both directions are only framed (object, opcode, size), not decoded, apart from
wl_display.get_registry, wl_registry.bind and the data-control objects' own
messages.

Usage: sbx-clip-guest --listen PATH --upstream PATH --broker PATH
"""

import argparse
import array
import base64
import json
import os
import select
import socket
import struct
import sys
import threading

PROG = "sbx-clip-guest"
MANAGERS = {
    # registry name (far above anything the proxy hands out) -> (interface, version)
    0xDC000001: ("zwlr_data_control_manager_v1", 2),
    0xDC000002: ("ext_data_control_manager_v1", 1),
}
# Text types, best first; what the host offers is its own choice (wl-copy).
TEXT_TYPES = ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT"]
SENSITIVE_TYPE = "x-kde-passwordManagerHint"
MAX_TEXT = 32 * 1024  # the broker's request limit is 64 KiB, base64 included
MAX_OFFERS = 64  # mime types per source
MAX_FDS = 28  # libwayland's per-message limit
# Ids of objects the server creates (ours: the offers) start here, and a client
# takes a new one only if it is the lowest free: so ours are handed out that
# way, which holds as long as the display proxy creates none on the same
# connection. It doesn't for a clipboard client, which binds only the seat.
SERVER_ID_BASE = 0xFF000000


def log(msg):
    print(f"{PROG}: {msg}", file=sys.stderr, flush=True)


class Protocol(Exception):
    pass


def string_arg(body, off):
    """(string, next offset) of the string argument at `off` in `body`."""
    if off + 4 > len(body):
        raise Protocol("truncated string")
    (n,) = struct.unpack_from("<I", body, off)
    end = off + 4 + ((n + 3) & ~3)
    if n == 0 or end > len(body):
        raise Protocol("bad string")
    return body[off + 4 : off + 4 + n - 1].decode("utf-8", "replace"), end


def u32_arg(body, off):
    if off + 4 > len(body):
        raise Protocol("truncated argument")
    return struct.unpack_from("<I", body, off)[0]


def message(obj, opcode, args=b""):
    return struct.pack("<II", obj, ((8 + len(args)) << 16) | opcode) + args


def string(s):
    b = s.encode() + b"\0"
    return struct.pack("<I", len(b)) + b + b"\0" * (-len(b) % 4)


def frames(buf):
    """Split `buf` into complete messages [(obj, opcode, body, raw)] and the
    incomplete rest."""
    out = []
    off = 0
    while len(buf) - off >= 8:
        obj, word = struct.unpack_from("<II", buf, off)
        size = word >> 16
        if size < 8:
            raise Protocol("bad message size")
        if len(buf) - off < size:
            break
        out.append((obj, word & 0xFFFF, buf[off + 8 : off + size], buf[off : off + size]))
        off += size
    return out, buf[off:]


def recv(sock):
    """(bytes, fds) from `sock`; (b"", []) at end of stream."""
    data, anc, _flags, _addr = sock.recvmsg(65536, socket.CMSG_SPACE(MAX_FDS * 4))
    fds = []
    for level, kind, payload in anc:
        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
            a = array.array("i")
            a.frombytes(payload[: len(payload) - len(payload) % a.itemsize])
            fds.extend(a)
    return data, fds


def send(sock, data, fds=()):
    """All of `data` (not empty) to `sock`, `fds` along with its first bytes."""
    fds = list(fds)
    while data:
        if fds:
            anc = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds[:MAX_FDS]))]
            # A few bytes per batch of descriptors: a stream socket delivers
            # none without data, and a receiver takes at most MAX_FDS at once.
            n = sock.sendmsg([data[: 8 if len(fds) > MAX_FDS else 4096]], anc)
            fds = fds[MAX_FDS:]
        else:
            n = sock.send(data)
        data = data[n:]


class Shared:
    """What every client of this VM shares: the last text copied, and the
    broker."""

    def __init__(self, broker_path):
        self.broker_path = broker_path
        self.lock = threading.Lock()
        self.text = None  # bytes, or None when nothing of ours is copied
        self.sensitive = False

    def ask(self, req):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(10)
                s.connect(self.broker_path)
                s.sendall((json.dumps(req) + "\n").encode())
                line = b""
                while not line.endswith(b"\n"):
                    c = s.recv(4096)
                    if not c:
                        break
                    line += c
            answer = json.loads(line) if line else {}
        except (OSError, ValueError) as e:
            log(f"broker: {e}")
            return False
        if answer.get("type") != "granted":
            log(f"broker: {answer.get('reason') or answer.get('message') or 'no answer'}")
            return False
        return True

    def copy(self, text, sensitive):
        with self.lock:
            self.text, self.sensitive = text, sensitive
        return self.ask({"op": "clipboard", "data": base64.b64encode(text).decode(), "sensitive": sensitive})

    def clear(self):
        with self.lock:
            self.text, self.sensitive = None, False
        return self.ask({"op": "clipboard", "clear": True})

    def current(self):
        with self.lock:
            return self.text, self.sensitive


class Client:
    """One client connection and its connection to the display proxy."""

    def __init__(self, conn, upstream, shared):
        self.c = conn
        self.s = upstream
        self.shared = shared
        self.wlock = threading.Lock()  # writes to the client
        self.registries = set()
        self.mine = {}  # object id -> {"kind": manager|device|source|offer, ...}
        self.cfds = []  # descriptors from the client, not yet passed on
        self.sfds = []  # and from the display proxy
        self.dead = False

    # ── To the client ────────────────────────────────────────────────────────
    def to_client(self, data, fds=()):
        with self.wlock:
            if self.dead:
                for fd in fds:
                    os.close(fd)
                return
            try:
                send(self.c, data, fds)
            except OSError:
                self.dead = True
            finally:
                for fd in fds:
                    os.close(fd)

    def delete_id(self, obj):
        self.to_client(message(1, 1, struct.pack("<I", obj)))  # wl_display.delete_id

    def offer_own(self, device):
        """The device's selection: what this VM copied last, or nothing."""
        text, sensitive = self.shared.current()
        if text is None:
            return self.to_client(message(device, 1, struct.pack("<I", 0)))  # selection(null)
        offer = SERVER_ID_BASE
        while offer in self.mine:
            offer += 1
        self.mine[offer] = {"kind": "offer", "text": text}
        out = message(device, 0, struct.pack("<I", offer))  # data_offer(new id)
        for t in TEXT_TYPES + ([SENSITIVE_TYPE] if sensitive else []):
            out += message(offer, 0, string(t))  # offer(mime type)
        out += message(device, 1, struct.pack("<I", offer))  # selection(offer)
        self.to_client(out)

    # ── The data-control objects' requests ──────────────────────────────────
    def request(self, obj, opcode, body):
        o = self.mine[obj]
        kind = o["kind"]
        if kind == "manager":
            if opcode == 0:  # create_data_source(new id)
                self.mine[u32_arg(body, 0)] = {"kind": "source", "types": []}
            elif opcode == 1:  # get_data_device(new id, seat)
                dev = u32_arg(body, 0)
                self.mine[dev] = {"kind": "device"}
                self.offer_own(dev)
                self.to_client(message(dev, 3, struct.pack("<I", 0)))  # primary_selection(null)
            elif opcode == 2:  # destroy
                del self.mine[obj]
                self.delete_id(obj)
        elif kind == "source":
            if opcode == 0:  # offer(mime type)
                t, _ = string_arg(body, 0)
                if len(o["types"]) < MAX_OFFERS:
                    o["types"].append(t)
            elif opcode == 1:  # destroy
                del self.mine[obj]
                self.delete_id(obj)
        elif kind == "device":
            if opcode == 0:  # set_selection(source or null)
                self.set_selection(obj, u32_arg(body, 0))
            elif opcode == 1:  # destroy
                del self.mine[obj]
                self.delete_id(obj)
            # 2: set_primary_selection: not handled (the source stays unused).
        elif kind == "offer":
            if opcode == 0:  # receive(mime type, fd)
                if not self.cfds:
                    raise Protocol("receive without a file descriptor")
                fd = self.cfds.pop(0)
                threading.Thread(target=self.serve, args=(fd, o["text"]), daemon=True).start()
            elif opcode == 1:  # destroy (a server-side id: no delete_id)
                del self.mine[obj]

    @staticmethod
    def serve(fd, text):
        try:
            with os.fdopen(fd, "wb", closefd=True) as f:
                f.write(text)
        except OSError:
            pass

    def set_selection(self, device, source):
        if source == 0:
            threading.Thread(target=self.shared.clear, daemon=True).start()
            return
        src = self.mine.get(source)
        if not src or src["kind"] != "source":
            raise Protocol("set_selection with an unknown source")
        mime = next((t for t in TEXT_TYPES if t in src["types"]), None)
        if mime is None:
            log(f"not copied: no text among {src['types'][:8]}")
            self.to_client(message(source, 1))  # cancelled
            return
        sensitive = SENSITIVE_TYPE in src["types"]
        r, w = os.pipe2(os.O_CLOEXEC)
        self.to_client(message(source, 0, string(mime)), [w])  # send(mime type, fd)
        threading.Thread(target=self.take, args=(r, source, sensitive), daemon=True).start()

    def take(self, r, source, sensitive):
        """Read the source's text, hand it to the host, cancel the source."""
        text = b""
        complete = False
        try:
            while len(text) <= MAX_TEXT and select.select([r], [], [], 5)[0]:
                chunk = os.read(r, 65536)
                if not chunk:
                    complete = True
                    break
                text += chunk
        except OSError as e:
            log(f"reading the copied text: {e}")
        finally:
            os.close(r)
        if len(text) > MAX_TEXT:
            log(f"not copied: more than {MAX_TEXT} bytes")
        elif not complete:
            log("not copied: the app didn't finish writing the text")
        else:
            self.shared.copy(text, sensitive)
        # The host owns the text now (or nothing was copied): either way this
        # source is done.
        if source in self.mine:
            self.to_client(message(source, 1))  # cancelled

    # ── The two streams ─────────────────────────────────────────────────────
    def from_client(self, data):
        msgs, rest = frames(data)
        forward = b""
        ours = False
        for obj, opcode, body, raw in msgs:
            if obj in self.mine:
                ours = True
                self.request(obj, opcode, body)
                continue
            if obj == 1 and opcode == 1:  # wl_display.get_registry(new id)
                reg = u32_arg(body, 0)
                self.registries.add(reg)
                for name, (iface, version) in MANAGERS.items():
                    self.to_client(message(reg, 0, struct.pack("<I", name) + string(iface) + struct.pack("<I", version)))
            elif obj in self.registries and opcode == 0:  # wl_registry.bind
                name = u32_arg(body, 0)
                if name in MANAGERS:
                    iface, off = string_arg(body, 4)
                    if iface != MANAGERS[name][0]:
                        raise Protocol("bind with the wrong interface")
                    self.mine[u32_arg(body, off + 4)] = {"kind": "manager"}
                    ours = True
                    continue
            forward += raw
        if self.cfds and ours and forward:
            # Whose descriptors these are can't be told without decoding every
            # protocol. A clipboard client's connection carries nothing else.
            raise Protocol("file descriptors in a batch for both us and the compositor")
        if forward:
            # Descriptors go with the first complete messages after them; with
            # none yet (a message still arriving), they wait.
            fds, self.cfds = ([], self.cfds) if ours else (self.cfds, [])
            try:
                send(self.s, forward, fds)
            finally:
                for fd in fds:
                    os.close(fd)
        return rest

    def run(self):
        cbuf = b""
        sbuf = b""
        try:
            while not self.dead:
                ready, _, _ = select.select([self.c, self.s], [], [])
                if self.c in ready:
                    data, fds = recv(self.c)
                    self.cfds += fds
                    if not data:
                        break
                    cbuf = self.from_client(cbuf + data)
                if self.s in ready:
                    data, fds = recv(self.s)
                    self.sfds += fds
                    if not data:
                        break
                    # Whole messages only, so ours never land inside one.
                    msgs, sbuf = frames(sbuf + data)
                    if msgs:
                        fds, self.sfds = self.sfds, []
                        self.to_client(b"".join(m[3] for m in msgs), fds)
        except Protocol as e:
            log(f"closing a client: {e}")
        except OSError:
            pass
        finally:
            with self.wlock:
                self.dead = True
            for fd in self.cfds + self.sfds:
                os.close(fd)
            for sock in (self.c, self.s):
                try:
                    sock.close()
                except OSError:
                    pass


def main():
    ap = argparse.ArgumentParser(prog=PROG)
    ap.add_argument("--listen", required=True)
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--broker", required=True)
    a = ap.parse_args()
    shared = Shared(a.broker)
    try:
        os.unlink(a.listen)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    old = os.umask(0o077)
    try:
        srv.bind(a.listen)
    finally:
        os.umask(old)
    srv.listen(64)
    log(f"listening on {a.listen}, display {a.upstream}")
    while True:
        conn, _ = srv.accept()
        up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
        try:
            up.connect(a.upstream)
        except OSError as e:
            log(f"no display at {a.upstream}: {e.strerror}")
            conn.close()
            up.close()
            continue
        threading.Thread(target=Client(conn, up, shared).run, daemon=True).start()


if __name__ == "__main__":
    main()
