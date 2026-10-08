"""Give a running sandbox VM more of the user's folders (temporary grants).

The VM has a virtio-fs share served by `crosvm device fs`, of an EMPTY view
(RTDIR/view): the device never holds the user's home. A grant has the root
attach helper (lib/broker/attach.py, op vm-path) bind the folder into that
device's jail at its path relative to the home, then asks the guest to bind it
at the same absolute path.

  sbx-grants hub --home DIR --dir RTDIR --attach CLIENT --vm NAME [--launch DIR]
      Host, as the user, one per VM. Holds the guest agent's connection
      (RTDIR/guest.sock, reached through the vsock relay as service "grants")
      and serves requests on RTDIR/ctl.sock. --launch: the launch's runtime
      dir as the attach helper (on the host) knows it, when this unit sees it
      elsewhere (a per-project VM's units see theirs at a fixed path); RTDIR's
      parent otherwise.
  sbx-grants request RTDIR PATH [rw|ro]
      Host: ask a VM's hub to grant PATH (a folder inside the user's home,
      canonical: what the user approved, never resolved again on the way, and
      opened by the attach helper without following symlinks). Used by the
      launchers and the sandbox broker; exits non-zero on failure.
  sbx-grants guest --port CID --mount DIR --home HOME --owner UID:GID
      Guest, as root: connect to the hub through the relay and perform the
      mounts it asks for (bind DIR/<relative> onto the real path, which must be
      inside HOME; both walked without following a symlink, the mount made on
      the folder that walk opened). It connects from a privileged vsock port,
      which only the guest's root can bind, and the host relay takes "grants"
      from no other (lib/vm/vsock-relay.py).

"ro" makes the host-side mount read-only (and the guest's bind). Removing a
grant is not supported: it lasts until the VM stops.
"""

import argparse
import errno
import json
import os
import socket
import subprocess
import sys
import threading

HOST_CID = 2
# Seconds: the guest agent's answer to one mount, the attach helper, waiting
# for an earlier grant to finish, and a request in all (those, plus the 30 for
# the guest agent to connect).
GUEST_TIMEOUT = 20
SHARE_TIMEOUT = 60
LOCK_TIMEOUT = 60
REQUEST_TIMEOUT = 180


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
    def __init__(self, home, rtdir, attach, vm, launch=None):
        self.home = os.path.realpath(home)
        self.rtdir = rtdir
        self.launch = launch or os.path.dirname(rtdir)
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

    def share(self, path, mode):
        # The helper wants the launch's runtime dir, as the host names it.
        try:
            r = subprocess.run(
                [self.attach, "vm", self.vm, self.launch, path, mode],
                capture_output=True,
                text=True,
                timeout=SHARE_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("the attach helper didn't answer")
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip() or "couldn't share the folder with the VM")

    def drop_guest(self, sock):
        with self.guest_ready:
            if self.guest and self.guest[0] is sock:
                self.guest = None
        sock.close()

    def grant(self, path, mode):
        # Exactly the path asked for (the broker shows the user this one):
        # resolving it again here would follow a link swapped in since.
        if not os.path.isabs(path) or path.startswith("//") or os.path.normpath(path) != path:
            raise ValueError(f"{path} is not a canonical path")
        if not path.startswith(self.home + "/"):
            raise ValueError(f"{path} is not a folder inside {self.home}")
        rel = path[len(self.home):]  # "/Documents/x": relative to the share, leading "/"
        if not self.lock.acquire(timeout=LOCK_TIMEOUT):
            raise RuntimeError("another grant to this VM is still in progress")
        try:
            if (path, mode) in self.granted:
                return
            self.share(path, mode)
            with self.guest_ready:
                if not self.guest_ready.wait_for(lambda: self.guest is not None, timeout=30):
                    raise RuntimeError("the VM's grant agent isn't connected")
                sock, f = self.guest
            # A guest agent that doesn't answer loses its connection (it
            # reconnects), so it can't hold up every later grant.
            try:
                sock.settimeout(GUEST_TIMEOUT)
                send_line(sock, {"op": "mount", "rel": rel, "path": path, "ro": mode == "ro"})
                reply = read_line(f)
            except (OSError, ValueError, ConnectionError) as e:
                self.drop_guest(sock)
                raise RuntimeError(f"the VM's grant agent didn't answer ({e})")
            if not isinstance(reply, dict) or not reply.get("ok"):
                error = reply.get("error") if isinstance(reply, dict) else None
                raise RuntimeError(str(error or "the guest couldn't mount it"))
            self.granted.append((path, mode))
            log(f"granted {path} ({mode})")
        finally:
            self.lock.release()

    def serve_ctl(self):
        s = listen(os.path.join(self.rtdir, "ctl.sock"))
        while True:
            conn, _ = s.accept()
            threading.Thread(target=self.handle_ctl, args=(conn,), daemon=True).start()

    def handle_ctl(self, conn):
        try:
            conn.settimeout(10)
            f = conn.makefile("rb")
            req = read_line(f)
            conn.settimeout(None)
            self.grant(str(req["path"]), "ro" if req.get("mode") == "ro" else "rw")
            send_line(conn, {"ok": True})
        except Exception as e:
            try:
                send_line(conn, {"ok": False, "error": str(e)})
            except OSError:
                pass
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
    hub = Hub(args.home, args.dir, args.attach, args.vm, args.launch)
    threading.Thread(target=hub.accept_guest, daemon=True).start()
    hub.serve_ctl()


def run_request(args):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(REQUEST_TIMEOUT)
    try:
        s.connect(os.path.join(args.dir, "ctl.sock"))
    except OSError as e:
        print(f"grants: {args.dir}: {e.strerror or e}", file=sys.stderr)
        return 1
    # Not realpath: the path goes as given (the hub refuses a non-canonical one).
    path = args.path if os.path.isabs(args.path) else os.path.join(os.getcwd(), args.path)
    try:
        send_line(s, {"path": path, "mode": args.mode})
        reply = read_line(s.makefile("rb"))
    except (OSError, ConnectionError, ValueError):
        print("grants: no answer from the VM", file=sys.stderr)
        return 1
    if not reply.get("ok"):
        print(f"grants: {reply.get('error')}", file=sys.stderr)
        return 1
    return 0


# ── Guest: the agent ─────────────────────────────────────────────────────────
# Root in the guest, working in folders the guest user controls (the home, and
# the share, whose folders are the VM uid's on the host: the user's in here).
# Both paths are walked from a held fd one component at a time, never through
# a symlink, and the mount goes onto the fd that walk ended on (open_tree +
# move_mount), so nothing the user swaps in on the way (~/Documents/x -> /etc)
# redirects it. As lib/broker/attach.py's make_mountpoint.

SYS_open_tree = 428
SYS_move_mount = 429
SYS_mount_setattr = 442
OPEN_TREE_CLONE = 1
AT_EMPTY_PATH = 0x1000
AT_RECURSIVE = 0x8000
MOVE_MOUNT_F_EMPTY_PATH = 0x4
MOVE_MOUNT_T_EMPTY_PATH = 0x40
MOUNT_ATTR_RDONLY = 0x1
_libc = None


def libc():
    global _libc
    if _libc is None:
        import ctypes

        _libc = ctypes.CDLL(None, use_errno=True)
        _libc.syscall.restype = ctypes.c_long
    return _libc


def check(ret, what):
    if ret < 0:
        import ctypes

        e = ctypes.get_errno()
        raise OSError(e, f"{what}: {os.strerror(e)}")
    return ret


def canonical(path):
    return (
        isinstance(path, str)
        and path.startswith("/")
        and not path.startswith("//")
        and "\0" not in path
        and os.path.normpath(path) == path
    )


def walk(path, create=None):
    """O_PATH fd for the folder `path` (absolute, canonical), walked from / on
    held fds without following a symlink in any component. `create` (home,
    uid, gid): make missing folders (mkdirat), the user's under the home."""
    if not canonical(path):
        raise ValueError(f"{path!r}: not a canonical path")
    flags = os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = os.open("/", flags)
    here = ""
    try:
        for part in [p for p in path.split("/") if p]:
            here += "/" + part
            try:
                nfd = os.open(part, flags, dir_fd=fd)
            except FileNotFoundError:
                if create is None:
                    raise
                home, uid, gid = create
                os.mkdir(part, 0o755, dir_fd=fd)
                if here.startswith(home + "/"):
                    os.chown(part, uid, gid, dir_fd=fd, follow_symlinks=False)
                nfd = os.open(part, flags, dir_fd=fd)
            except (NotADirectoryError, OSError) as e:
                if isinstance(e, NotADirectoryError) or e.errno == errno.ELOOP:
                    raise ValueError(f"{path}: {here} is a symlink or not a folder")
                raise
            os.close(fd)
            fd = nfd
        return fd
    except BaseException:
        os.close(fd)
        raise


def bind_fd(src_fd, dst_fd, ro):
    """Bind the folder `src_fd` onto `dst_fd` (both held), read-only if `ro`."""
    import struct
    import ctypes

    c = libc()
    tree = check(
        c.syscall(SYS_open_tree, src_fd, b"", OPEN_TREE_CLONE | os.O_CLOEXEC | AT_EMPTY_PATH | AT_RECURSIVE),
        "open_tree",
    )
    try:
        if ro:
            attr = struct.pack("QQQQ", MOUNT_ATTR_RDONLY, 0, 0, 0)
            buf = ctypes.create_string_buffer(attr, len(attr))
            check(c.syscall(SYS_mount_setattr, tree, b"", AT_EMPTY_PATH | AT_RECURSIVE, buf, len(attr)), "mount_setattr")
        check(
            c.syscall(SYS_move_mount, tree, b"", dst_fd, b"", MOVE_MOUNT_F_EMPTY_PATH | MOVE_MOUNT_T_EMPTY_PATH),
            "move_mount",
        )
    finally:
        os.close(tree)


def guest_mount(mountdir, owner, rel, path, ro, bind=bind_fd):
    home = owner[0]
    if not canonical(path) or not path.startswith(home + "/"):
        raise ValueError(f"{path!r}: not a folder inside {home}")
    if not rel.startswith("/") or not canonical(mountdir + rel):
        raise ValueError("bad path")
    try:
        src = walk(mountdir + rel)
    except FileNotFoundError:
        raise FileNotFoundError(mountdir + rel)
    try:
        dst = walk(path, create=owner)
        try:
            bind(src, dst, ro)
        finally:
            os.close(dst)
    finally:
        os.close(src)


def bind_privileged(s):
    """Bind a vsock port below 1024 (CAP_NET_BIND_SERVICE in the guest's own
    namespace: its root), by which the host relay knows this is the agent."""
    for port in range(1023, 511, -1):
        try:
            s.bind((socket.VMADDR_CID_ANY, port))
            return
        except OSError as e:
            if e.errno != errno.EADDRINUSE:
                raise
    raise OSError(errno.EADDRINUSE, "no free privileged vsock port")


def run_guest(args):
    # The host relay is up before the VM boots; a failure here means the host
    # side went away, and systemd restarts the agent.
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    bind_privileged(s)
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
    h.add_argument("--launch", help="the launch's runtime dir on the host (default: --dir's parent)")
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
