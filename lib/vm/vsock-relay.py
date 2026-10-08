"""Carry named unix-socket services between a sandbox VM and the host, over vsock.

Guest side (`guest`): listen on local unix sockets; each accepted connection is
carried to the host (CID 2) on vsock port = the guest's own CID (`--port`, which
the host hands the guest), prefixed with one line naming the service
("pulse\n").

Host side (`host`): listen on vsock port = the VM's CID; accept only connections
whose peer CID is that VM's; read the service line; connect to the unix socket
mapped to that name; splice both ways. A service the VM wasn't given is refused.
"grants" (the guest's root folder-grant agent, which dials the host itself,
lib/vm/grants.py) is taken only from a privileged source port (< 1024), which
only the guest's root can bind, so no other guest process can stand in for it.

File descriptors (SCM_RIGHTS) cannot cross vsock. The host side therefore
mediates D-Bus authentication and rejects Unix fd negotiation before splicing
the binary message stream. Other services are spliced verbatim (PulseAudio
must have shm/memfd off).

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
MAX_AUTH_LINE = 16384
# Services only the guest's root may reach: vsock ports below 1024 need
# CAP_NET_BIND_SERVICE in the guest (af_vsock's LAST_RESERVED_PORT).
PRIVILEGED = {"grants"}
LAST_RESERVED_PORT = 1023


def read_auth_line(conn):
    # Do not read ahead: BEGIN can be followed immediately by binary messages.
    line = bytearray()
    while len(line) < MAX_AUTH_LINE:
        byte = conn.recv(1)
        if not byte:
            raise EOFError("D-Bus authentication disconnected")
        line.extend(byte)
        if line.endswith(b"\r\n"):
            return bytes(line)
    raise ValueError("D-Bus authentication line too long")


def auth_word(line):
    # libdbus takes a space or a tab after the command: split on any blank.
    words = line[:-2].split(None, 1)
    return words[0] if words else b""


def dbus_auth(client, server):
    """Forward SASL exchanges but never negotiate fds on the host connection.

    Run on the host, so even a guest bypassing its local relay cannot negotiate
    a feature that this transport cannot carry. Authentication and identity
    checks remain the upstream proxy's responsibility.
    """
    if client.recv(1) != b"\0":
        raise ValueError("D-Bus authentication must start with NUL")
    server.sendall(b"\0")
    authenticated = False
    while True:
        line = read_auth_line(client)
        command = auth_word(line)
        if command == b"NEGOTIATE_UNIX_FD":
            client.sendall(b"ERROR Unix file descriptor passing is unavailable over vsock\r\n")
            continue
        if command == b"BEGIN":
            if not authenticated or line != b"BEGIN\r\n":
                raise ValueError("D-Bus BEGIN before authentication or with arguments")
            server.sendall(line)
            return
        server.sendall(line)
        reply = read_auth_line(server)
        status = auth_word(reply)
        if status == b"AGREE_UNIX_FD":
            raise ValueError("unexpected D-Bus fd agreement")
        if status == b"OK":
            authenticated = True
        elif status == b"REJECTED":
            authenticated = False
        client.sendall(reply)


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


def service_path(services, name, port):
    """The unix socket for service `name` asked for from guest port `port`, or
    None if the VM wasn't given it (or a privileged one, from an unprivileged
    port)."""
    if not name:
        return None
    if name in PRIVILEGED and not 0 <= port <= LAST_RESERVED_PORT:
        return None
    return services.get(name)


def serve_host(cid, services):
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    # Port = the VM's CID: unique per running VM. Binding fails if anything else
    # holds it, and then the VM doesn't start (the VMM unit requires this one).
    s.bind((socket.VMADDR_CID_ANY, cid))
    s.listen(64)
    log(f"serving {', '.join(sorted(services))} to CID {cid}")
    notify_ready()

    def handle(conn, peer, port):
        try:
            conn.settimeout(10)
            name = read_name(conn)
            conn.settimeout(None)
        except (OSError, UnicodeDecodeError):
            name = None
        path = service_path(services, name, port)
        if path is None:
            log(f"CID {peer} port {port}: refused service {name!r}")
            conn.close()
            return
        try:
            down = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
            down.connect(path)
        except OSError as e:
            log(f"{name}: {path}: {e}")
            conn.close()
            return
        # Only the plain bus is raw D-Bus. Capture VMs carry "capture-dbus"
        # instead: the capture adapter's own framing, whose host end does the
        # SASL exchange itself and refuses the guest's fd negotiation.
        if name == "dbus":
            try:
                conn.settimeout(10)
                down.settimeout(10)
                dbus_auth(conn, down)
                conn.settimeout(None)
                down.settimeout(None)
            except (OSError, EOFError, ValueError) as e:
                log(f"dbus: {e}")
                conn.close()
                down.close()
                return
        splice(conn, down)

    while True:
        conn, (peer, port) = s.accept()
        if peer != cid:
            log(f"refused a connection from CID {peer}")
            conn.close()
            continue
        threading.Thread(target=handle, args=(conn, peer, port), daemon=True).start()


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
