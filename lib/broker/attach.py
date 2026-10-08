"""sbx-attach: bind a folder or the camera into a RUNNING container sandbox
(and a VM's grants share), or widen a running sandbox's IP filter (grant-net).

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
  {"op": "allow-ip", "sandbox": NAME, "unit": UNIT, "addr": "IP or CIDR"}
  → {"ok": true, "attached": N} | {"ok": false, "error": "..."}

What it will do, whoever asks (the user is the only one who can):
  - path: only into sandboxes that run as the user (their user namespace is the
    user's), and only a source the USER can open: it is opened by a child that
    has dropped to the user's uid, gids and groups, so no permission (path
    traversal included) is bypassed by root resolving it. The user could reach
    every such file anyway; this changes what one of their own sandboxes sees.
    The path must be canonical, and is opened as it is named: no symlink in any
    component (openat2 RESOLVE_NO_SYMLINKS), so a sandbox that can write the
    folder's parent can't swap in a link elsewhere between the user's approval
    (of exactly this path) and the mount.
    Read-only is enforced on the mount (MOUNT_ATTR_RDONLY), but like a VM's
    read-only grant it's a guard, not a boundary: the sandbox runs as the user.
  - vm-path: the same, for a sandbox VM's folder grants: into the VM's grants
    virtio-fs device (`crosvm device fs`, run as the VM's own uid), whose jail
    root is the launch's empty grants view ($rtdir/grantsfs/view). The folder
    is mounted at its path relative to the user's home inside that view, which
    the guest agent then binds at the real path (lib/vm/grants.py). So that
    device never holds the user's home, only what was granted. The clone is
    idmapped (MOUNT_ATTR_IDMAP) onto the VM's uid and group, as the VM's other
    shares are (lib/vm/root.py `stage`): the user's files show as the VM's,
    what it creates lands on disk as the user's, and other owners show as
    nobody. A folder with a mount under it that can't be idmapped (FUSE, NFS)
    is refused: shared unmapped, the VM would act as the user on it.
  - camera: the host's UVC capture devices (uvcvideo; never loopback or capture
    cards) as device nodes at their own paths, into any configured sandbox. A
    dedicated-uid sandbox also gets an ACL for its uid on those nodes, which its
    unit removes when it stops.
  - allow-ip: sbx-broker's grant-net. Adds one address or prefix to the
    IPAddressAllow= of a running unit the sandbox registered as its network
    units (`systemctl set-property --runtime`), and nothing else: never
    IPAddressDeny=, never a reset, no other unit or property. (Not polkit:
    polkit can't tell which property a set-property call changes.)
A sandbox is found from the record the host side of its launcher wrote
(nixpak's bwrapinfo.json, which the sandbox can't reach), and, for systemd
units, the unit's cgroup; the process must still be the one named there, run
as the expected uid, and see the expected /.flatpak-info. Records and the VM's
grants view sit in directories the user (or the app) owns: they are resolved
from a held fd, strictly beneath it (openat2: no symlink, no other mount).
Mount points are made by a child that has dropped to the sandbox's own uid,
without following symlinks, and only on the sandbox's own tmpfs; root only
does the mount.
"""

import ctypes
import errno
import fnmatch
import ipaddress
import json
import os
import pwd
import re
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
SYS_openat2 = 437
SYS_mount_setattr = 442

OPEN_TREE_CLONE = 1
OPEN_TREE_CLOEXEC = os.O_CLOEXEC
AT_FDCWD = -100
AT_EMPTY_PATH = 0x1000
AT_RECURSIVE = 0x8000
MOVE_MOUNT_F_EMPTY_PATH = 0x4
MOVE_MOUNT_T_EMPTY_PATH = 0x40
MOUNT_ATTR_RDONLY = 0x1
MOUNT_ATTR_NOSUID = 0x2
MOUNT_ATTR_NODEV = 0x4
MOUNT_ATTR_IDMAP = 0x00100000
RESOLVE_NO_XDEV = 0x01
RESOLVE_NO_MAGICLINKS = 0x02
RESOLVE_NO_SYMLINKS = 0x04
RESOLVE_BENEATH = 0x08
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


def mount_setattr(fd, attr_set, userns_fd=0):
    attr = struct.pack("QQQQ", attr_set, 0, 0, userns_fd)
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


# ── Idmaps (as lib/vm/root.py's) ──────────────────────────────────────────────


def idmap_lines(pairs):
    """uid_map/gid_map text for `pairs` of (id on disk, id seen through the
    mount), one id each: nothing else is mapped (it shows as the overflow id),
    and no id twice on either side."""
    if not pairs:
        raise Refused("an idmap needs an id")
    ins, outs, lines = set(), set(), []
    for a, b in pairs:
        for v in (a, b):
            if type(v) is not int or not 0 <= v < 0xFFFFFFFF:
                raise Refused(f"bad id {v!r} in an idmap")
        if a in ins or b in outs:
            raise Refused("an id twice in an idmap")
        ins.add(a)
        outs.add(b)
        lines.append(f"{a} {b} 1\n")
    return "".join(lines)


def idmap_userns(uids, gids):
    """An fd for a new user namespace whose only ids are `uids` and `gids`
    (idmap_lines), for MOUNT_ATTR_IDMAP. A child unshares it and waits while
    this process writes its maps (setgroups denied first) and opens it;
    nothing ever runs in it."""
    umap, gmap = idmap_lines(uids), idmap_lines(gids)
    ready_r, ready_w = os.pipe()
    done_r, done_w = os.pipe()
    child = os.fork()
    if child == 0:
        try:
            os.close(ready_r)
            os.close(done_w)
            os.unshare(os.CLONE_NEWUSER)
            os.write(ready_w, b"1")
            os.read(done_r, 1)
        finally:
            os._exit(0)
    os.close(ready_w)
    os.close(done_r)
    try:
        if os.read(ready_r, 1) != b"1":
            raise Refused("couldn't make the idmap's user namespace")
        for name, text in (("setgroups", "deny"), ("uid_map", umap), ("gid_map", gmap)):
            fd = os.open(f"/proc/{child}/{name}", os.O_WRONLY | os.O_CLOEXEC)
            try:
                os.write(fd, text.encode())
            finally:
                os.close(fd)
        return os.open(f"/proc/{child}/ns/user", os.O_RDONLY | os.O_CLOEXEC)
    finally:
        os.close(ready_r)
        os.close(done_w)
        os.waitpid(child, 0)


def idmap_to(tree, user, vm_pw, path):
    """Idmap the detached `tree`: the user's uid and group onto the VM's."""
    if vm_pw.pw_uid in (0, user["uid"]) or vm_pw.pw_gid in (0, user["gid"]):
        raise Refused("the VM's uid can't stand in for the user")
    userns = idmap_userns([(user["uid"], vm_pw.pw_uid)], [(user["gid"], vm_pw.pw_gid)])
    try:
        mount_setattr(tree, MOUNT_ATTR_IDMAP, userns)
    except OSError as e:
        raise Refused(
            f"{path} (or a mount under it: FUSE, NFS, ...) can't be idmapped ({e.strerror}),"
            " and shared as it is the VM would act as you on it"
        )
    finally:
        os.close(userns)


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


def openat2(dir_fd, path, flags, resolve):
    how = struct.pack("QQQ", flags | os.O_CLOEXEC, 0, resolve)
    buf = ctypes.create_string_buffer(how, len(how))
    fd = libc.syscall(SYS_openat2, ctypes.c_long(dir_fd), os.fsencode(path), buf, ctypes.c_size_t(len(how)))
    if fd < 0:
        e = ctypes.get_errno()
        raise OSError(e, f"{path}: {os.strerror(e)}")
    return fd


# Below a directory another uid controls: never out of it, through a symlink
# (any component) or onto another mount (a FUSE mount of the user's).
BENEATH = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_XDEV


def read_small(path, limit=65536, dir_fd=None):
    # Records live in directories the user (or the app) can write: no symlinks,
    # no FIFOs to hang on, regular files only, bounded. With dir_fd, `path` is
    # resolved strictly beneath it (BENEATH).
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    fd = openat2(dir_fd, path, flags, BENEATH) if dir_fd is not None else os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(f"{path} is not a regular file")
        return os.read(fd, limit).decode("utf-8", "replace")
    finally:
        os.close(fd)


def records(runtime_dir):
    """(child pid, app id) for every nixpak sandbox launched with this runtime dir.

    The runtime dir is the user's (or the app's), in a root-owned /run: it is
    opened without following a link in any component and must be a tmpfs (not
    a FUSE mount its owner put there), and everything below it is resolved
    from that fd, strictly beneath it (BENEATH)."""
    try:
        rfd = openat2(AT_FDCWD, runtime_dir, os.O_RDONLY | os.O_DIRECTORY, RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS)
    except OSError:
        return []
    try:
        if statfs_type(rfd) != TMPFS_MAGIC:
            log(f"{runtime_dir} isn't a tmpfs; ignoring its records")
            return []
        try:
            bfd = openat2(rfd, ".flatpak", os.O_RDONLY | os.O_DIRECTORY, BENEATH)
        except OSError:
            return []
        try:
            names = os.listdir(bfd)
            out = []
            for n in names:
                if not n.startswith("nixpak-app-"):
                    continue
                try:
                    dfd = openat2(bfd, n, os.O_PATH | os.O_DIRECTORY, BENEATH)
                except OSError:
                    continue
                try:
                    pid = int(json.loads(read_small("bwrapinfo.json", dir_fd=dfd))["child-pid"])
                    app = flatpak_name(read_small("info", dir_fd=dfd))
                except (OSError, ValueError, KeyError, TypeError):
                    continue
                finally:
                    os.close(dfd)
                if pid > 1 and app:
                    out.append((pid, app))
            return out
        finally:
            os.close(bfd)
    finally:
        os.close(rfd)


def unit_pids(unit):
    pids = set()
    # Containers in a restricted network mode run in netpolicy's slice.
    for parent in ("system.slice", "system.slice/system-sandboxnet.slice"):
        for root, _dirs, files in os.walk(f"/sys/fs/cgroup/{parent}/{unit}"):
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


def pidfd_gid(pidfd):
    """The (real) gid of the process behind `pidfd`."""
    with open(f"/proc/self/fdinfo/{pidfd}") as f:
        pid = next(int(l.split()[1]) for l in f if l.startswith("Pid:"))
    with open(f"/proc/{pid}/status") as f:
        return next(int(l.split()[1]) for l in f if l.startswith("Gid:"))


def mountpoint_as(owner, gid, path, is_dir, close=()):
    """make_mountpoint, done AS the sandbox's own uid and gid (inside its
    namespace, which the caller has already joined): its tmpfs is that uid's
    to write, and a sandbox's tmpfs only takes new files from ids its user
    namespace maps, which root's aren't. `close`: fds the unprivileged child
    must not hold. Returns the O_PATH fd."""
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    child = os.fork()
    if child == 0:
        a.close()
        try:
            for fd in close:
                os.close(fd)
            os.setgroups([])
            os.setresgid(gid, gid, gid)
            os.setresuid(owner, owner, owner)
            fd = make_mountpoint(path, is_dir, owner)
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
        raise Refused(msg.decode("utf-8", "replace").removeprefix("err:") or "no mount point")
    return fds[0]


def attach(pidfd, tree, path, is_dir, owner):
    """Mount the detached `tree` at `path` inside the sandbox of `pidfd`, from a
    child (so this process keeps the host namespace). The mount point is made
    by a grandchild that has dropped to the sandbox's uid (mountpoint_as);
    only the mount itself is root's."""
    gid = pidfd_gid(pidfd)
    r, w = os.pipe()
    child = os.fork()
    if child == 0:
        os.close(r)
        try:
            os.setns(pidfd, CLONE_NEWNS)
            # The detached tree and the pidfd stay out of the unprivileged child.
            dst = mountpoint_as(owner, gid, path, is_dir, close=(tree, pidfd, w))
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


def canonical(path):
    """`path` if it's absolute and canonical (what realpath gives: no ".", "..",
    empty or trailing components); otherwise Refused. Nothing resolves it again
    here, so it has to be the path the user approved."""
    if (
        not isinstance(path, str)
        or not path.startswith("/")
        or path.startswith("//")
        or "\0" in path
        or os.path.normpath(path) != path
    ):
        raise Refused("path must be absolute and canonical")
    return path


def open_exact(path):
    """O_PATH fd for the folder at exactly `path` (canonical): no symlink is
    followed in any component, and the kernel's name for what was opened is
    `path` itself."""
    try:
        fd = openat2(AT_FDCWD, path, os.O_PATH | os.O_DIRECTORY, RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS)
    except OSError as e:
        if e.errno == errno.ELOOP:
            raise Refused(f"{path}: a symlink is in the way")
        raise
    try:
        if os.readlink(f"/proc/self/fd/{fd}") != path:
            raise Refused(f"{path} isn't where it was asked for")
    except BaseException:
        os.close(fd)
        raise
    return fd


def open_as_user(user, path):
    """O_PATH fd for the folder at exactly `path` (open_exact), opened with the
    user's credentials."""
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    child = os.fork()
    if child == 0:
        a.close()
        try:
            os.setgroups(os.getgrouplist(user["name"], user["gid"]))
            os.setresgid(user["gid"], user["gid"], user["gid"])
            os.setresuid(user["uid"], user["uid"], user["uid"])
            fd = open_exact(path)
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


def home_path(user, path):
    path = canonical(path)
    if not path.startswith(user["home"] + "/"):
        raise Refused("only folders inside your home can be granted")
    return path


def op_path(cfg, sb, name, req):
    if not sb.get("paths"):
        raise Refused("this sandbox can't take folders while running")
    user = cfg["user"]
    path = home_path(user, req.get("path"))
    fd = open_as_user(user, path)
    try:
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
                attach(pidfd, tree, path, True, user["uid"])
            finally:
                os.close(pidfd)
        return len(pidfds)
    finally:
        os.close(tree)


def vm_targets(cfg, vm, rtdir, owner, wait=10.0):
    """pidfds of the grants fs device of this VM launch: a process of the VM's
    uid (`owner`), in a user namespace that uid owns, whose root IS the
    launch's grants view."""
    base = f"/run/sandbox-vm/{vm}/"
    if os.path.realpath(rtdir) + "/" != rtdir.rstrip("/") + "/" or not rtdir.startswith(base):
        raise Refused("bad VM runtime dir")
    # $rtdir is root's; grantsfs/ and its view are the VM's uid's: resolved
    # beneath the launch dir, no symlink, no other mount.
    rfd = open_exact(os.path.normpath(rtdir))
    try:
        vfd = openat2(rfd, "grantsfs/view", os.O_PATH | os.O_DIRECTORY, BENEATH)
    except OSError:
        raise Refused("no grants view")
    finally:
        os.close(rfd)
    st = os.fstat(vfd)
    os.close(vfd)
    if st.st_uid != owner:
        raise Refused("the grants view isn't the VM's")
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
                if proc_uid(pid) != owner or userns_owner(pid) != owner:
                    raise Refused("not the VM's")
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
    vms = cfg.get("vms", {})
    if not isinstance(vm, str) or vm not in vms or not isinstance(rtdir, str):
        raise Refused("unknown VM")
    user = cfg["user"]
    path = home_path(user, req.get("path"))
    vm_pw = pwd.getpwnam(vms[vm])
    fd = open_as_user(user, path)
    try:
        tree = open_tree(fd, recursive=True)
    finally:
        os.close(fd)
    try:
        attr = MOUNT_ATTR_NOSUID | MOUNT_ATTR_NODEV
        if not req.get("write"):
            attr |= MOUNT_ATTR_RDONLY
        mount_setattr(tree, attr)
        idmap_to(tree, user, vm_pw, path)
        pidfds = vm_targets(cfg, vm, rtdir, vm_pw.pw_uid)
        if not pidfds:
            raise Refused(f"{vm}'s grants share isn't running")
        rel = path[len(user["home"]) :]
        for pidfd in pidfds:
            try:
                attach(pidfd, tree, rel, True, vm_pw.pw_uid)
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


# ── Network grants ───────────────────────────────────────────────────────────

UNIT_NAME = re.compile(r"[A-Za-z0-9:_.\\@-]{1,255}")


def op_allow_ip(cfg, req):
    """grant-net: one more address or prefix in IPAddressAllow= of a running unit
    the sandbox registered (an exact name or a glob, e.g. "...-net@*.service").
    A non-empty IPAddressAllow= assignment only ever adds; nothing else is set."""
    name = req.get("sandbox")
    patterns = cfg.get("netUnits", {}).get(name) if isinstance(name, str) else None
    if not patterns:
        raise Refused("this sandbox's network isn't filtered per sandbox")
    unit = req.get("unit")
    if (
        not isinstance(unit, str)
        or not UNIT_NAME.fullmatch(unit)
        or not any(fnmatch.fnmatchcase(unit, p) for p in patterns)
    ):
        raise Refused("not one of the sandbox's network units")
    try:
        net = ipaddress.ip_network(str(req.get("addr")), strict=False)
    except ValueError:
        raise Refused("addr must be an IP address or prefix")
    systemctl = cfg["systemctl"]
    r = subprocess.run(
        [systemctl, "show", "--property=ActiveState", "--value", "--", unit],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if r.stdout.strip() != "active":
        raise Refused(f"{unit} isn't running")
    r = subprocess.run(
        [systemctl, "set-property", "--runtime", "--", unit, f"IPAddressAllow={net}"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if r.returncode != 0:
        raise Refused(f"could not update {unit}: {r.stderr.strip()}")
    return net


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
        if req.get("op") == "allow-ip":
            net = op_allow_ip(cfg, req)
            log(f"{req.get('sandbox')}: {req.get('unit')}: IPAddressAllow+={net}")
            return reply({"ok": True, "attached": 1})
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
    except (Refused, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as e:
        log(f"{req if req is not None else data[:200]!r}: {e}")
        reply({"ok": False, "error": str(e)})


def client():
    """sbx-attach-client SANDBOX PATH rw|ro | SANDBOX attach (camera)
    | vm NAME RTDIR PATH rw|ro (a VM's folder grant)
    | allow-ip SANDBOX UNIT ADDR (grant-net)."""
    a = sys.argv[1:]
    if len(a) == 5 and a[0] == "vm" and a[4] in ("rw", "ro"):
        req = {"op": "vm-path", "vm": a[1], "rtdir": a[2], "path": a[3], "write": a[4] == "rw"}
    elif len(a) == 4 and a[0] == "allow-ip":
        req = {"op": "allow-ip", "sandbox": a[1], "unit": a[2], "addr": a[3]}
    elif len(a) == 3 and a[2] in ("rw", "ro"):
        req = {"op": "path", "sandbox": a[0], "path": a[1], "write": a[2] == "rw"}
    elif len(a) == 2 and a[1] == "attach":
        req = {"op": "camera", "sandbox": a[0]}
    else:
        print(
            "usage: sbx-attach-client SANDBOX PATH rw|ro | SANDBOX attach"
            " | vm NAME RTDIR PATH rw|ro | allow-ip SANDBOX UNIT ADDR",
            file=sys.stderr,
        )
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
