"""Carry named unix-socket services between a sandbox VM and the host, over vsock.

Guest side (`guest`): listen on local unix sockets; each accepted connection is
carried to the host (CID 2) on vsock port = the guest's own CID (`--port`, which
the host hands the guest), prefixed with one line naming the service
("pulse\n").

Host side (`host`): listen on vsock port = the VM's CID; accept only connections
whose peer CID is that VM's; read the service line; connect to the unix socket
mapped to that name; splice both ways. A service the VM wasn't given is refused.

The payload is spliced verbatim, never parsed. File descriptors (SCM_RIGHTS)
cannot cross vsock, so only protocols that work without them are carried
(PulseAudio with shm/memfd off, D-Bus without fd-passing calls).

  vsock-relay guest --port CID SERVICE=/run/sbx/x/sock ...
  vsock-relay host --cid CID SERVICE=/host/socket ...
"""

import argparse
import os
import socket
import sys
import threading

HOST_CID = 2
MAX_NAME = 64


def log(msg):
    print(f"vsock-relay: {msg}", file=sys.stderr, flush=True)


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def splice(a, b):
    t = threading.Thread(target=pump, args=(b, a), daemon=True)
    t.start()
    pump(a, b)
    t.join()
    a.close()
    b.close()


def parse_map(items):
    out = {}
    for item in items:
        name, sep, path = item.partition("=")
        if not sep or not name or not path or len(name) > MAX_NAME or "\n" in name:
            sys.exit(f"vsock-relay: bad SERVICE=PATH: {item!r}")
        out[name] = path
    return out


def serve_guest(port, services):
    def handle(conn, name):
        try:
            up = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
            up.connect((HOST_CID, port))
            up.sendall(name.encode() + b"\n")
        except OSError as e:
            log(f"{name}: host unreachable: {e}")
            conn.close()
            return
        splice(conn, up)

    def listen(name, path):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
        s.bind(path)
        os.chmod(path, 0o666)
        s.listen(64)
        while True:
            conn, _ = s.accept()
            threading.Thread(target=handle, args=(conn, name), daemon=True).start()

    threads = [
        threading.Thread(target=listen, args=(n, p), daemon=True) for n, p in services.items()
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


def notify_ready():
    """sd_notify(READY=1) for Type=notify units: the port is bound."""
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM | socket.SOCK_CLOEXEC) as n:
        n.connect(addr)
        n.sendall(b"READY=1")


def read_name(conn):
    buf = b""
    while len(buf) <= MAX_NAME:
        c = conn.recv(1)
        if not c:
            return None
        if c == b"\n":
            return buf.decode("ascii", "strict")
        buf += c
    return None


def serve_host(cid, services):
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    # Port = the VM's CID: unique per running VM. Binding fails if anything else
    # holds it, and then the VM doesn't start (the VMM unit requires this one).
    s.bind((socket.VMADDR_CID_ANY, cid))
    s.listen(64)
    log(f"serving {', '.join(sorted(services))} to CID {cid}")
    notify_ready()

    def handle(conn, peer):
        try:
            conn.settimeout(10)
            name = read_name(conn)
            conn.settimeout(None)
        except (OSError, UnicodeDecodeError):
            name = None
        path = services.get(name) if name else None
        if path is None:
            log(f"CID {peer}: refused service {name!r}")
            conn.close()
            return
        try:
            down = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
            down.connect(path)
        except OSError as e:
            log(f"{name}: {path}: {e}")
            conn.close()
            return
        splice(conn, down)

    while True:
        conn, (peer, _) = s.accept()
        if peer != cid:
            log(f"refused a connection from CID {peer}")
            conn.close()
            continue
        threading.Thread(target=handle, args=(conn, peer), daemon=True).start()


def main():
    ap = argparse.ArgumentParser(prog="vsock-relay")
    sub = ap.add_subparsers(dest="side", required=True)
    g = sub.add_parser("guest")
    g.add_argument("--port", type=int, required=True)
    g.add_argument("services", nargs="+", metavar="SERVICE=PATH")
    h = sub.add_parser("host")
    h.add_argument("--cid", type=int, required=True)
    h.add_argument("services", nargs="+", metavar="SERVICE=PATH")
    a = ap.parse_args()
    services = parse_map(a.services)
    if a.side == "guest":
        serve_guest(a.port, services)
    else:
        serve_host(a.cid, services)


if __name__ == "__main__":
    main()
