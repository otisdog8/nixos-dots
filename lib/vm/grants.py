"""Give a running sandbox VM more of the user's folders (temporary grants).

The VM has a virtio-fs share served by `crosvm device fs`, of an EMPTY view
(RTDIR/view): the device never holds the user's home. A grant has the root
attach helper (lib/broker/attach.py, op vm-path) bind the folder into that
device's jail at its path relative to the home, then asks the guest to bind it
at the same absolute path.

  sbx-grants hub --home DIR --dir RTDIR --attach CLIENT --vm NAME
      Host, as the user, one per VM. Holds the guest agent's connection
      (RTDIR/guest.sock, reached through the vsock relay as service "grants")
      and serves requests on RTDIR/ctl.sock.
  sbx-grants request RTDIR PATH [rw|ro]
      Host: ask a VM's hub to grant PATH (a folder inside the user's home).
      Used by the launchers and the sandbox broker; exits non-zero on failure.
  sbx-grants guest --port CID --mount DIR --home HOME --owner UID:GID
      Guest, as root: connect to the hub through the relay and perform the
      mounts it asks for (bind DIR/<relative> onto the real path).

"ro" makes the host-side mount read-only (and the guest's bind). Removing a
grant is not supported: it lasts until the VM stops.
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import threading

HOST_CID = 2


def log(msg):
    print(f"grants: {msg}", file=sys.stderr, flush=True)


def send_line(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode())


def read_line(f):
    line = f.readline()
    if not line:
        raise ConnectionError("closed")
    return json.loads(line)


# ── Host: the hub ────────────────────────────────────────────────────────────
class Hub:
    def __init__(self, home, rtdir, attach, vm):
        self.home = os.path.realpath(home)
        self.rtdir = rtdir
        self.attach = attach
        self.vm = vm
        self.guest = None  # (sock, file)
        self.guest_ready = threading.Condition()
        self.lock = threading.Lock()  # one grant at a time
        self.granted = []

    def accept_guest(self):
        s = listen(os.path.join(self.rtdir, "guest.sock"))
        while True:
            conn, _ = s.accept()
            with self.guest_ready:
                if self.guest:
                    self.guest[0].close()
                self.guest = (conn, conn.makefile("rb"))
                self.guest_ready.notify_all()
            log("guest agent connected")

    def share(self, real, mode):
        # RTDIR is <launch runtime dir>/grants; the helper wants the launch's.
        r = subprocess.run(
            [self.attach, "vm", self.vm, os.path.dirname(self.rtdir), real, mode],
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip() or "couldn't share the folder with the VM")

    def grant(self, path, mode):
        real = os.path.realpath(path)
        if not real.startswith(self.home + "/") or not os.path.isdir(real):
            raise ValueError(f"{path} is not a folder inside {self.home}")
        rel = real[len(self.home):]  # "/Documents/x": relative to the share, leading "/"
        with self.lock:
            if (real, mode) in self.granted:
                return
            self.share(real, mode)
            with self.guest_ready:
                if not self.guest_ready.wait_for(lambda: self.guest is not None, timeout=30):
                    raise RuntimeError("the VM's grant agent isn't connected")
                sock, f = self.guest
            send_line(sock, {"op": "mount", "rel": rel, "path": real, "ro": mode == "ro"})
            reply = read_line(f)
            if not reply.get("ok"):
                raise RuntimeError(reply.get("error", "the guest couldn't mount it"))
            self.granted.append((real, mode))
            log(f"granted {real} ({mode})")

    def serve_ctl(self):
        s = listen(os.path.join(self.rtdir, "ctl.sock"))
        while True:
            conn, _ = s.accept()
            threading.Thread(target=self.handle_ctl, args=(conn,), daemon=True).start()

    def handle_ctl(self, conn):
        try:
            f = conn.makefile("rb")
            req = read_line(f)
            self.grant(str(req["path"]), "ro" if req.get("mode") == "ro" else "rw")
            send_line(conn, {"ok": True})
        except Exception as e:
            send_line(conn, {"ok": False, "error": str(e)})
        finally:
            conn.close()


def listen(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    s.bind(path)
    os.chmod(path, 0o600)
    s.listen(8)
    return s


def run_hub(args):
    hub = Hub(args.home, args.dir, args.attach, args.vm)
    threading.Thread(target=hub.accept_guest, daemon=True).start()
    hub.serve_ctl()


def run_request(args):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(os.path.join(args.dir, "ctl.sock"))
    except OSError as e:
        print(f"grants: {args.dir}: {e.strerror}", file=sys.stderr)
        return 1
    send_line(s, {"path": os.path.abspath(args.path), "mode": args.mode})
    try:
        reply = read_line(s.makefile("rb"))
    except (ConnectionError, ValueError):
        print("grants: no answer from the VM", file=sys.stderr)
        return 1
    if not reply.get("ok"):
        print(f"grants: {reply.get('error')}", file=sys.stderr)
        return 1
    return 0


# ── Guest: the agent ─────────────────────────────────────────────────────────
def mkdirs(path, owner):
    """Create path and its missing ancestors; the ones under the user's home
    belong to the user (so the app can still create their siblings)."""
    if os.path.isdir(path):
        return
    mkdirs(os.path.dirname(path), owner)
    os.mkdir(path, 0o755)
    home, uid, gid = owner
    if path.startswith(home + "/"):
        os.chown(path, uid, gid)


def guest_mount(mountdir, owner, rel, path, ro):
    if not os.path.isabs(path) or ".." in path.split("/") or not rel.startswith("/"):
        raise ValueError("bad path")
    src = mountdir + rel
    if not os.path.isdir(src):
        raise FileNotFoundError(src)
    mkdirs(path, owner)
    subprocess.run(["mount", "--bind", "--", src, path], check=True)
    if ro:
        subprocess.run(["mount", "-o", "remount,bind,ro", "--", path], check=True)


def run_guest(args):
    # The host relay is up before the VM boots; a failure here means the host
    # side went away, and systemd restarts the agent.
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    s.connect((HOST_CID, args.port))
    s.sendall(b"grants\n")
    f = s.makefile("rb")
    uid, gid = (int(x) for x in args.owner.split(":"))
    owner = (args.home, uid, gid)
    log("connected to the host")
    while True:
        req = read_line(f)
        try:
            if req.get("op") != "mount":
                raise ValueError("unknown op")
            guest_mount(args.mount, owner, str(req["rel"]), str(req["path"]), bool(req.get("ro")))
            send_line(s, {"ok": True})
        except Exception as e:
            send_line(s, {"ok": False, "error": str(e)})


def main():
    ap = argparse.ArgumentParser(prog="sbx-grants")
    sub = ap.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("hub")
    h.add_argument("--home", required=True)
    h.add_argument("--dir", required=True)
    h.add_argument("--attach", required=True, help="sbx-attach-client")
    h.add_argument("--vm", required=True, help="the VM instance's name")
    r = sub.add_parser("request")
    r.add_argument("dir")
    r.add_argument("path")
    r.add_argument("mode", nargs="?", default="rw", choices=["rw", "ro"])
    g = sub.add_parser("guest")
    g.add_argument("--port", type=int, required=True)
    g.add_argument("--mount", required=True)
    g.add_argument("--home", required=True)
    g.add_argument("--owner", required=True, help="UID:GID of the user's home")
    a = ap.parse_args()
    if a.cmd == "hub":
        run_hub(a)
    elif a.cmd == "request":
        sys.exit(run_request(a))
    else:
        run_guest(a)


if __name__ == "__main__":
    main()
