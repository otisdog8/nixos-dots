"""sbx-attach: bind a folder or the camera into a RUNNING container sandbox.

A bwrap sandbox's mount namespace is fixed when it starts, so a folder the user
grants later (sbx-broker's grant-path) or a camera the user allows (camera)
has to be mounted into it from outside. That needs root: only root can clone a
host mount (open_tree OPEN_TREE_CLONE) and attach it in another namespace
(setns + move_mount), the way `machinectl bind` does for containers.

Runs as root, one process per connection (systemd socket activation,
Accept=yes, stdin = the connection). The socket is the user's alone (0600), and
the peer is checked again here. One JSON request line, one JSON reply line:
  {"op": "path", "sandbox": NAME, "path": "/home/<user>/...", "write": bool}
  {"op": "camera", "sandbox": NAME}
  {"op": "vm-path", "vm": NAME, "rtdir": "/run/sandbox-vm/NAME/ID", "path": ..., "write": bool}
  → {"ok": true, "attached": N} | {"ok": false, "error": "..."}

What it will do, whoever asks (the user is the only one who can):
  - path: only into sandboxes that run as the user (their user namespace is the
    user's), and only a source the USER can open: it is opened by a child that
    has dropped to the user's uid, gids and groups, so no permission (path
    traversal included) is bypassed by root resolving it. The user could reach
    every such file anyway; this changes what one of their own sandboxes sees.
    Read-only is enforced on the mount (MOUNT_ATTR_RDONLY), but like a VM's
    read-only grant it's a guard, not a boundary: the sandbox runs as the user.
  - vm-path: the same, for a sandbox VM's folder grants: into the VM's grants
    virtio-fs device (`crosvm device fs`, run as the user), whose jail root is
    the launch's empty grants view ($rtdir/grants/view). The folder is mounted
    at its path relative to the user's home inside that view, which the guest
    agent then binds at the real path (lib/vm/grants.py). So that device never
    holds the user's home, only what was granted.
  - camera: the host's UVC capture devices (uvcvideo; never loopback or capture
    cards) as device nodes at their own paths, into any configured sandbox. A
    dedicated-uid sandbox also gets an ACL for its uid on those nodes, which its
    unit removes when it stops.
A sandbox is found from the record the host side of its launcher wrote
(nixpak's bwrapinfo.json, which the sandbox can't reach), and, for systemd
units, the unit's cgroup; the process must still be the one named there, run
as the expected uid, and see the expected /.flatpak-info. Mount points are made
without following symlinks, and only on the sandbox's own tmpfs.
"""

import ctypes
import json
import os
import pwd
import socket
import stat
import struct
import subprocess
import sys
import time

PROG = "sbx-attach"

libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long

# Same numbers on every architecture (asm-generic, added after the split).
SYS_open_tree = 428
SYS_move_mount = 429
SYS_mount_setattr = 442

OPEN_TREE_CLONE = 1
OPEN_TREE_CLOEXEC = os.O_CLOEXEC
AT_EMPTY_PATH = 0x1000
AT_RECURSIVE = 0x8000
MOVE_MOUNT_F_EMPTY_PATH = 0x4
MOVE_MOUNT_T_EMPTY_PATH = 0x40
MOUNT_ATTR_RDONLY = 0x1
MOUNT_ATTR_NOSUID = 0x2
MOUNT_ATTR_NODEV = 0x4
CLONE_NEWNS = 0x20000
NS_GET_OWNER_UID = 0xB704  # _IO(0xb7, 0x4)
TMPFS_MAGIC = 0x01021994


class Refused(Exception):
    pass


def check(ret, what):
    if ret < 0:
        e = ctypes.get_errno()
        raise OSError(e, f"{what}: {os.strerror(e)}")
    return ret


def open_tree(fd, recursive):
    flags = OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC | AT_EMPTY_PATH
    if recursive:
        flags |= AT_RECURSIVE
    return check(libc.syscall(SYS_open_tree, fd, b"", flags), "open_tree")


def mount_setattr(fd, attr_set):
    attr = struct.pack("QQQQ", attr_set, 0, 0, 0)
    buf = ctypes.create_string_buffer(attr, len(attr))
    check(
        libc.syscall(SYS_mount_setattr, fd, b"", AT_EMPTY_PATH | AT_RECURSIVE, buf, len(attr)),
        "mount_setattr",
    )


def move_mount(tree, dst_fd):
    check(
        libc.syscall(
            SYS_move_mount, tree, b"", dst_fd, b"", MOVE_MOUNT_F_EMPTY_PATH | MOVE_MOUNT_T_EMPTY_PATH
        ),
        "move_mount",
    )


def statfs_type(fd):
    # struct statfs: f_type is the first field (long).
    buf = ctypes.create_string_buffer(256)
    check(libc.fstatfs(fd, buf), "fstatfs")
    return struct.unpack_from("l", buf)[0]


# ── Finding a sandbox ────────────────────────────────────────────────────────


def proc_uid(pid):
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("Uid:"):
                return int(line.split()[1])
    raise Refused(f"no uid for {pid}")


def userns_owner(pid):
    fd = os.open(f"/proc/{pid}/ns/user", os.O_RDONLY | os.O_CLOEXEC)
    try:
        import fcntl

        buf = bytearray(4)
        fcntl.ioctl(fd, NS_GET_OWNER_UID, buf)
        return struct.unpack("I", bytes(buf))[0]
    finally:
        os.close(fd)


def flatpak_name(text):
    section = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
        elif section == "Application" and line.startswith("name="):
            return line[len("name=") :]
    return None


def read_small(path, limit=65536):
    # Records live in directories the user (or the app) can write: no symlinks,
    # no FIFOs to hang on, regular files only, bounded.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(f"{path} is not a regular file")
        return os.read(fd, limit).decode("utf-8", "replace")
    finally:
        os.close(fd)


def records(runtime_dir):
    """(child pid, app id) for every nixpak sandbox launched with this runtime dir."""
    base = os.path.join(runtime_dir, ".flatpak")
    try:
        names = os.listdir(base)
    except OSError:
        return []
    out = []
    for n in names:
        if not n.startswith("nixpak-app-"):
            continue
        d = os.path.join(base, n)
        try:
            pid = int(json.loads(read_small(os.path.join(d, "bwrapinfo.json")))["child-pid"])
            app = flatpak_name(read_small(os.path.join(d, "info")))
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if pid > 1 and app:
            out.append((pid, app))
    return out


def unit_pids(unit):
    path = f"/sys/fs/cgroup/system.slice/{unit}"
    pids = set()
    for root, _dirs, files in os.walk(path):
        if "cgroup.procs" in files:
            with open(os.path.join(root, "cgroup.procs")) as f:
                pids.update(int(x) for x in f.read().split())
    return pids


def targets(cfg, sb, name, wait=10.0):
    """pidfds of this sandbox's running instances, each checked; waits a little
    for one to appear (a launcher asks for the camera as the app starts)."""
    deadline = time.monotonic() + wait
    while True:
        out = find_targets(cfg, sb, name)
        if out or time.monotonic() >= deadline:
            return out
        time.sleep(0.25)


def find_targets(cfg, sb, name):
    user = cfg["user"]
    want_uid = pwd.getpwnam(sb["appUser"]).pw_uid if sb.get("appUser") else user["uid"]
    runtime = f"/run/{sb['appUser']}" if sb.get("appUser") else user["runtimeDir"]
    allowed = unit_pids(sb["unit"]) if sb.get("unit") else None
    host_mnt = os.stat("/proc/self/ns/mnt").st_ino
    seen, out = set(), []
    for pid, app in records(runtime):
        if app != sb["appId"]:
            continue
        try:
            pidfd = os.pidfd_open(pid)
        except OSError:
            continue
        try:
            if allowed is not None and pid not in allowed:
                raise Refused("not in the app's unit")
            if proc_uid(pid) != want_uid:
                raise Refused("wrong uid")
            if userns_owner(pid) != want_uid:
                raise Refused("user namespace not the app's")
            if flatpak_name(read_small(f"/proc/{pid}/root/.flatpak-info")) != sb["appId"]:
                raise Refused("different .flatpak-info")
            mnt = os.stat(f"/proc/{pid}/ns/mnt").st_ino
            if mnt == host_mnt or mnt in seen:
                raise Refused("not a separate sandbox")
            # Still the same process the checks above looked at.
            libc_pidfd_signal(pidfd)
            seen.add(mnt)
            out.append(pidfd)
        except (Refused, OSError) as e:
            log(f"{name}: skipping pid {pid}: {e}")
            os.close(pidfd)
    return out


def libc_pidfd_signal(pidfd):
    SYS_pidfd_send_signal = 424
    check(libc.syscall(SYS_pidfd_send_signal, pidfd, 0, None, 0), "pidfd_send_signal")


# ── Mounting ─────────────────────────────────────────────────────────────────


def make_mountpoint(path, is_dir, owner, root="/"):
    """In the sandbox's namespace (we're inside it): an fd for `path`, creating
    missing parts with mkdirat on held fds. Never follows a symlink; creates
    only on tmpfs (the sandbox's own root and dirs), never in a host bind."""
    parts = [p for p in path.split("/") if p]
    if not parts or any(p in (".", "..") for p in parts):
        raise Refused(f"bad target {path}")
    fd = os.open(root, os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for i, part in enumerate(parts):
            last = i == len(parts) - 1
            flags = os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC
            try:
                nfd = os.open(part, flags | (os.O_DIRECTORY if (is_dir or not last) else 0), dir_fd=fd)
            except FileNotFoundError:
                if statfs_type(fd) != TMPFS_MAGIC:
                    raise Refused(f"{path}: won't create {part} outside the sandbox's tmpfs")
                if is_dir or not last:
                    os.mkdir(part, 0o755, dir_fd=fd)
                    os.chown(part, owner, -1, dir_fd=fd, follow_symlinks=False)
                    nfd = os.open(part, flags | os.O_DIRECTORY, dir_fd=fd)
                else:
                    wfd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=fd)
                    os.close(wfd)
                    nfd = os.open(part, flags, dir_fd=fd)
            except NotADirectoryError:
                raise Refused(f"{path}: {part} is a symlink or not a folder")
            st = os.fstat(nfd)
            if stat.S_ISLNK(st.st_mode):
                os.close(nfd)
                raise Refused(f"{path}: {part} is a symlink")
            os.close(fd)
            fd = nfd
        return fd
    except BaseException:
        os.close(fd)
        raise


def attach(pidfd, tree, path, is_dir, owner):
    """Mount the detached `tree` at `path` inside the sandbox of `pidfd`, from a
    child (so this process keeps the host namespace)."""
    r, w = os.pipe()
    child = os.fork()
    if child == 0:
        os.close(r)
        try:
            os.setns(pidfd, CLONE_NEWNS)
            dst = make_mountpoint(path, is_dir, owner)
            move_mount(tree, dst)
            os.write(w, b"ok")
            os._exit(0)
        except BaseException as e:
            os.write(w, str(e).encode()[:500])
            os._exit(1)
    os.close(w)
    msg = os.read(r, 600).decode("utf-8", "replace")
    os.close(r)
    _, status = os.waitpid(child, 0)
    if status != 0 or msg != "ok":
        raise Refused(msg or "attach failed")


def open_as_user(user, path):
    """O_PATH fd for `path`, opened with the user's credentials."""
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    child = os.fork()
    if child == 0:
        a.close()
        try:
            os.setgroups(os.getgrouplist(user["name"], user["gid"]))
            os.setresgid(user["gid"], user["gid"], user["gid"])
            os.setresuid(user["uid"], user["uid"], user["uid"])
            fd = os.open(path, os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC)
            socket.send_fds(b, [b"ok"], [fd])
            os._exit(0)
        except BaseException as e:
            b.send(f"err:{e}".encode()[:500])
            os._exit(1)
    b.close()
    msg, fds, _flags, _addr = socket.recv_fds(a, 600, 1)
    a.close()
    os.waitpid(child, 0)
    if msg != b"ok" or not fds:
        raise Refused(msg.decode("utf-8", "replace").removeprefix("err:") or "can't open it")
    return fds[0]


def op_path(cfg, sb, name, req):
    if not sb.get("paths"):
        raise Refused("this sandbox can't take folders while running")
    user = cfg["user"]
    path = req.get("path")
    if not isinstance(path, str) or not path.startswith("/") or "\0" in path:
        raise Refused("path must be absolute")
    fd = open_as_user(user, path)
    try:
        real = os.readlink(f"/proc/self/fd/{fd}")
        if not real.startswith(user["home"] + "/"):
            raise Refused("only folders inside your home can be granted")
        tree = open_tree(fd, recursive=True)
    finally:
        os.close(fd)
    try:
        attr = MOUNT_ATTR_NOSUID | MOUNT_ATTR_NODEV
        if not req.get("write"):
            attr |= MOUNT_ATTR_RDONLY
        mount_setattr(tree, attr)
        pidfds = targets(cfg, sb, name)
        if not pidfds:
            raise Refused(f"{name} isn't running")
        for pidfd in pidfds:
            try:
                attach(pidfd, tree, real, True, user["uid"])
            finally:
                os.close(pidfd)
        return len(pidfds)
    finally:
        os.close(tree)


def vm_targets(cfg, vm, rtdir, wait=10.0):
    """pidfds of the grants fs device of this VM launch: a process of the user,
    in a user namespace the user owns, whose root IS the launch's grants view."""
    user = cfg["user"]
    base = f"/run/sandbox-vm/{vm}/"
    if os.path.realpath(rtdir) + "/" != rtdir.rstrip("/") + "/" or not rtdir.startswith(base):
        raise Refused("bad VM runtime dir")
    view = os.path.join(rtdir, "grants", "view")
    st = os.lstat(view)
    if not stat.S_ISDIR(st.st_mode):
        raise Refused("no grants view")
    want = (st.st_dev, st.st_ino)
    deadline = time.monotonic() + wait
    while True:
        out = []
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            pid = int(d)
            try:
                r = os.stat(f"/proc/{pid}/root")
                if (r.st_dev, r.st_ino) != want:
                    continue
                pidfd = os.pidfd_open(pid)
            except OSError:
                continue
            try:
                if proc_uid(pid) != user["uid"] or userns_owner(pid) != user["uid"]:
                    raise Refused("not the user's")
                libc_pidfd_signal(pidfd)
                out.append(pidfd)
            except (Refused, OSError) as e:
                log(f"{vm}: skipping pid {pid}: {e}")
                os.close(pidfd)
        if out or time.monotonic() >= deadline:
            return out
        time.sleep(0.25)


def op_vm_path(cfg, req):
    vm = req.get("vm")
    rtdir = req.get("rtdir")
    if vm not in cfg.get("vms", []) or not isinstance(rtdir, str):
        raise Refused("unknown VM")
    user = cfg["user"]
    path = req.get("path")
    if not isinstance(path, str) or not path.startswith("/") or "\0" in path:
        raise Refused("path must be absolute")
    fd = open_as_user(user, path)
    try:
        real = os.readlink(f"/proc/self/fd/{fd}")
        if not real.startswith(user["home"] + "/"):
            raise Refused("only folders inside your home can be granted")
        tree = open_tree(fd, recursive=True)
    finally:
        os.close(fd)
    try:
        attr = MOUNT_ATTR_NOSUID | MOUNT_ATTR_NODEV
        if not req.get("write"):
            attr |= MOUNT_ATTR_RDONLY
        mount_setattr(tree, attr)
        pidfds = vm_targets(cfg, vm, rtdir)
        if not pidfds:
            raise Refused(f"{vm}'s grants share isn't running")
        rel = real[len(user["home"]) :]
        for pidfd in pidfds:
            try:
                attach(pidfd, tree, rel, True, user["uid"])
            finally:
                os.close(pidfd)
        return len(pidfds)
    finally:
        os.close(tree)


def uvc_nodes():
    nodes = []
    base = "/sys/class/video4linux"
    for n in sorted(os.listdir(base)):
        try:
            driver = os.path.basename(os.readlink(f"{base}/{n}/device/driver"))
        except OSError:
            continue
        if driver == "uvcvideo":
            nodes.append(f"/dev/{n}")
    return nodes


def op_camera(cfg, sb, name, req):
    if not sb.get("camera"):
        raise Refused("this sandbox has no camera access")
    nodes = uvc_nodes()
    if not nodes:
        raise Refused("no camera is plugged in")
    pidfds = targets(cfg, sb, name)
    if not pidfds:
        raise Refused(f"{name} isn't running")
    try:
        if sb.get("appUser"):
            # The app's own uid isn't the seat user that uaccess grants; its
            # unit's ExecStopPost removes this again.
            subprocess.run([cfg["setfacl"], "-m", f"u:{sb['appUser']}:rw", "--", *nodes], check=True)
        owner = pwd.getpwnam(sb["appUser"]).pw_uid if sb.get("appUser") else cfg["user"]["uid"]
        for node in nodes:
            fd = os.open(node, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC)
            try:
                if not stat.S_ISCHR(os.fstat(fd).st_mode):
                    raise Refused(f"{node} isn't a device")
                tree = open_tree(fd, recursive=False)
            finally:
                os.close(fd)
            try:
                for pidfd in pidfds:
                    try:
                        attach(pidfd, tree, node, False, owner)
                    except Refused as e:
                        # Already there (bound at start, or attached before).
                        log(f"{name}: {node}: {e}")
            finally:
                os.close(tree)
        return len(pidfds)
    finally:
        for pidfd in pidfds:
            os.close(pidfd)


# ── Entry ────────────────────────────────────────────────────────────────────


def log(msg):
    print(f"{PROG}: {msg}", file=sys.stderr, flush=True)


def main():
    cfg = json.load(open(sys.argv[1]))
    user = cfg["user"]
    conn = socket.socket(fileno=os.dup(0))
    creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    _pid, uid, _gid = struct.unpack("3i", creds)

    def reply(obj):
        conn.sendall((json.dumps(obj) + "\n").encode())

    if uid not in (0, user["uid"]):
        log(f"refusing uid {uid}")
        return reply({"ok": False, "error": "not allowed"})
    data = b""
    while not data.endswith(b"\n") and len(data) < 8192:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    req = None
    try:
        req = json.loads(data)
        if req.get("op") == "vm-path":
            n = op_vm_path(cfg, req)
            log(f"vm {req.get('vm')}: {req.get('path')} → {n} device(s)")
            return reply({"ok": True, "attached": n})
        name = req.get("sandbox")
        sb = cfg["sandboxes"].get(name) if isinstance(name, str) else None
        if sb is None:
            raise Refused("unknown sandbox")
        op = req.get("op")
        if op == "path":
            n = op_path(cfg, sb, name, req)
        elif op == "camera":
            n = op_camera(cfg, sb, name, req)
        else:
            raise Refused("unknown op")
        log(f"{name}: {op} {req.get('path', '')} → {n} sandbox(es)")
        reply({"ok": True, "attached": n})
    except (Refused, OSError, ValueError, KeyError) as e:
        log(f"{req if req is not None else data[:200]!r}: {e}")
        reply({"ok": False, "error": str(e)})


def client():
    """sbx-attach-client SANDBOX PATH rw|ro | SANDBOX attach (camera)
    | vm NAME RTDIR PATH rw|ro (a VM's folder grant)."""
    a = sys.argv[1:]
    if len(a) == 5 and a[0] == "vm" and a[4] in ("rw", "ro"):
        req = {"op": "vm-path", "vm": a[1], "rtdir": a[2], "path": a[3], "write": a[4] == "rw"}
    elif len(a) == 3 and a[2] in ("rw", "ro"):
        req = {"op": "path", "sandbox": a[0], "path": a[1], "write": a[2] == "rw"}
    elif len(a) == 2 and a[1] == "attach":
        req = {"op": "camera", "sandbox": a[0]}
    else:
        print("usage: sbx-attach-client SANDBOX PATH rw|ro | SANDBOX attach", file=sys.stderr)
        sys.exit(2)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(os.environ.get("SBX_ATTACH_SOCKET", "/run/sbx-attach.sock"))
    s.sendall((json.dumps(req) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    r = json.loads(data or b'{"ok": false, "error": "no reply"}')
    if not r.get("ok"):
        print(r.get("error", "failed"), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    if os.path.basename(sys.argv[0]).endswith("client") or os.environ.get("SBX_ATTACH_CLIENT"):
        client()
    else:
        main()
