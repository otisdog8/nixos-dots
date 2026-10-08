"""sbx-vm-root: the root steps of a sandbox VM (lib/vm/instance.nix), each run
from a confined root unit of its own (ProtectSystem=strict, a small capability
bounding set, no network).

  stage CONFIG BASE KEY [DIR]   (the -prep unit) the paths a user chooses
      (home storage entries, binds of ~ and absolute paths, projects, shared
      downloads, the document portal's view, the broker's sockets for a
      restricted VM's relay, and DIR, a per-project VM's project) mounted into
      BASE/stage/KEY, which only root can enter, for the VM's units to bind
      from (BindPaths=). Each is opened by a child that has dropped to the
      user's uid, gids and groups, without following a symlink in any
      component (openat2 RESOLVE_NO_SYMLINKS), so no permission is bypassed by
      root resolving it and nothing the VM wrote into a shared folder (a link
      where a nested entry should be) can redirect it. The one exception: a
      link straight into /nix/store (a home-manager file), which every guest
      sees anyway. What was opened is cloned (open_tree OPEN_TREE_CLONE, with
      its submounts, nosuid, nodev, read-only when the bind is) and moved onto
      a mount point in a private tmpfs at the stage, in the host's mount
      namespace, which is where systemd resolves BindPaths= sources. Private,
      so none of it propagates into any other unit's namespace.
  cleanup BASE KEY RT           (the -prep unit, on stop) unmounts the stage and
      removes the launch's runtime dir: each directory owned by someone else is
      emptied by a child running as its owner, then removed by root; never
      following a link, never leaving the filesystem.
  gpu-open RT BACKEND PRINCIPAL [CAPTURE] SETFACL
                                (the -gpu-open unit) once the virtio-nvgpu
      backend has made its sockets (waited for as the backend's uid), its
      directory becomes root's, so the backend can no longer swap what is in
      it, and the VMM's uid (and the capture helper's, on the inject socket)
      gets an ACL on the socket it opened without following a link.
  camera attach|detach RT PRINCIPAL CROSVM
                                (the -camera unit) USB video-class devices into
      the running VM over its control socket, opened without following a link
      and checked to be a socket of the VMM's uid.
  coresched BACKEND_UNIT VMM_UNIT SYSTEMCTL
                                (the -coresched unit, games) the backend's
      thread group gets the VMM's core-scheduling cookie. Both are pinned with
      pidfds and checked to be their units' main processes.

Every path root works on is checked first: each of its directories is root's
and writable by nobody else (open_trusted), so only root could have put
anything there.
"""

import ctypes
import errno
import json
import os
import pwd
import re
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import time

PROG = "sbx-vm-root"

libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long

# Same numbers on every architecture (asm-generic, added after the split).
SYS_open_tree = 428
SYS_move_mount = 429
SYS_fsopen = 430
SYS_fsconfig = 431
SYS_fsmount = 432
SYS_openat2 = 437
SYS_mount_setattr = 442

OPEN_TREE_CLONE = 1
AT_FDCWD = -100
AT_EMPTY_PATH = 0x1000
AT_RECURSIVE = 0x8000
MOVE_MOUNT_F_EMPTY_PATH = 0x4
MOVE_MOUNT_T_EMPTY_PATH = 0x40
MOUNT_ATTR_RDONLY = 0x1
MOUNT_ATTR_NOSUID = 0x2
MOUNT_ATTR_NODEV = 0x4
MOUNT_ATTR_NOEXEC = 0x8
MS_PRIVATE = 1 << 18
FSOPEN_CLOEXEC = 1
FSMOUNT_CLOEXEC = 1
FSCONFIG_SET_STRING = 1
FSCONFIG_CMD_CREATE = 6
MNT_DETACH = 2
UMOUNT_NOFOLLOW = 8
RESOLVE_NO_MAGICLINKS = 0x02
RESOLVE_NO_SYMLINKS = 0x04
CLONE_NEWNS = 0x20000
CAP_SYS_PTRACE = 19
PR_SCHED_CORE = 62
PR_SCHED_CORE_GET = 0
PR_SCHED_CORE_SHARE_TO = 2
PR_SCHED_CORE_SHARE_FROM = 3
SCOPE_THREAD = 0
SCOPE_THREAD_GROUP = 1

STORE = "/nix/store/"
# What a per-project path may contain (the launcher's own check, enforced here).
PROJECT_CHARS = re.compile(r"[A-Za-z0-9._/@+,=~ -]+")
# How long a child working as someone else may take (a FUSE view that hangs).
CHILD_TIMEOUT = 20


class Refused(Exception):
    pass


def log(msg):
    print(f"{PROG}: {msg}", file=sys.stderr, flush=True)


def check(ret, what):
    if ret < 0:
        e = ctypes.get_errno()
        raise OSError(e, f"{what}: {os.strerror(e)}")
    return ret


# ── Paths ────────────────────────────────────────────────────────────────────


def canonical(path):
    """`path` if it's absolute and canonical (no ".", "..", empty or trailing
    components); otherwise Refused."""
    if (
        not isinstance(path, str)
        or not path.startswith("/")
        or path.startswith("//")
        or "\0" in path
        or os.path.normpath(path) != path
    ):
        raise Refused(f"{path!r}: not an absolute, canonical path")
    return path


def open_trusted(path, uid=0, base_fd=None):
    """O_PATH fd for the directory `path`, checking every directory on the way
    (and `path` itself): no symlink, owned by `uid` (root), writable by nobody
    else. So nothing in it can have been put there by anyone but root. With
    `base_fd`, `path` is relative to that directory (tests)."""
    flags = os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    if base_fd is None:
        canonical(path)
        fd = os.open("/", flags)
        parts = [p for p in path.split("/") if p]
    else:
        fd = os.dup(base_fd)
        parts = [p for p in path.split("/") if p]
        if any(p in (".", "..") for p in parts):
            os.close(fd)
            raise Refused(f"{path!r}: not a plain path")
    try:
        trusted_dir(fd, path, uid)
        for part in parts:
            try:
                nfd = os.open(part, flags, dir_fd=fd)
            except (NotADirectoryError, OSError) as e:
                if isinstance(e, NotADirectoryError) or e.errno == errno.ELOOP:
                    raise Refused(f"{path}: {part} is a symlink or not a folder")
                raise
            os.close(fd)
            fd = nfd
            trusted_dir(fd, path, uid)
        return fd
    except BaseException:
        os.close(fd)
        raise


def trusted_dir(fd, path, uid):
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != uid or st.st_mode & 0o022:
        raise Refused(f"{path}: a folder on the way isn't root's alone")


def openat2(dirfd, path, flags, resolve):
    how = struct.pack("QQQ", flags | os.O_CLOEXEC, 0, resolve)
    buf = ctypes.create_string_buffer(how, len(how))
    return libc.syscall(SYS_openat2, ctypes.c_long(dirfd), os.fsencode(path), buf, ctypes.c_size_t(len(how)))


KINDS = {
    "dir": stat.S_ISDIR,
    "file": stat.S_ISREG,
    "any": lambda m: stat.S_ISDIR(m) or stat.S_ISREG(m),
    "socket": stat.S_ISSOCK,
}


def open_exact(path, kind):
    """O_PATH fd for the `kind` of object at exactly `path` (canonical): no
    symlink is followed in any component, and the kernel's name for what was
    opened is `path` itself. A file or "any" whose last component is a link
    into the store (home-manager's) opens the store file."""
    flags = os.O_PATH | (os.O_DIRECTORY if kind == "dir" else 0)
    fd = openat2(AT_FDCWD, path, flags, RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS)
    if fd < 0:
        e = ctypes.get_errno()
        if e == errno.ELOOP and kind in ("file", "any"):
            return open_store_link(path, kind)
        if e == errno.ELOOP:
            raise Refused(f"{path}: a symlink is in the way")
        if e == errno.ENOTDIR:
            raise Refused(f"{path}: not a folder")
        raise OSError(e, f"{path}: {os.strerror(e)}")
    try:
        if os.readlink(f"/proc/self/fd/{fd}") != path:
            raise Refused(f"{path} isn't where it was asked for")
        if not KINDS[kind](os.fstat(fd).st_mode):
            raise Refused(f"{path}: not a {kind}")
    except BaseException:
        os.close(fd)
        raise
    return fd


def open_store_link(path, kind):
    """`path`'s last component is a symlink: open what it names only if that
    is in the store (root's, immutable, and in every guest already)."""
    parent, name = os.path.split(path)
    pfd = open_exact(parent, "dir")
    try:
        target = os.readlink(name, dir_fd=pfd)
    except OSError:
        raise Refused(f"{path}: a symlink is in the way")
    finally:
        os.close(pfd)
    if not target.startswith(STORE) or os.path.normpath(target) != target:
        raise Refused(f"{path}: a symlink is in the way (to {target}, not the store)")
    fd = openat2(AT_FDCWD, target, os.O_PATH, RESOLVE_NO_MAGICLINKS)
    if fd < 0:
        e = ctypes.get_errno()
        raise OSError(e, f"{path} → {target}: {os.strerror(e)}")
    try:
        real = os.readlink(f"/proc/self/fd/{fd}")
        if not real.startswith(STORE) or not KINDS[kind](os.fstat(fd).st_mode):
            raise Refused(f"{path}: its link leaves the store")
    except BaseException:
        os.close(fd)
        raise
    return fd


def project_path(path):
    """A per-project VM's directory, from its unit's instance name: what the
    launcher checks, enforced here."""
    canonical(path)
    if path == "/":
        raise Refused("won't attach / (the whole host filesystem) as a project")
    if not PROJECT_CHARS.fullmatch(path):
        raise Refused(f"{path!r}: unsupported characters in a project path")
    return path


# ── Working as someone else ──────────────────────────────────────────────────


def drop_to(uid, gid, groups):
    os.setgroups(groups)
    os.setresgid(gid, gid, gid)
    os.setresuid(uid, uid, uid)


def user_creds(user):
    return user["uid"], user["gid"], os.getgrouplist(user["name"], user["gid"])


def as_user(creds, fn):
    """Run `fn` (returning an fd) in a child with `creds` (uid, gid, groups);
    the fd comes back over a socket. The child dies after CHILD_TIMEOUT."""
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    child = os.fork()
    if child == 0:
        a.close()
        try:
            signal.alarm(CHILD_TIMEOUT)
            drop_to(*creds)
            fd = fn()
            socket.send_fds(b, [b"ok"], [fd])
            os._exit(0)
        except BaseException as e:
            try:
                b.send(f"err:{type(e).__name__}:{e}".encode()[:600])
            finally:
                os._exit(1)
    b.close()
    try:
        msg, fds, _flags, _addr = socket.recv_fds(a, 700, 1)
    finally:
        a.close()
        os.waitpid(child, 0)
    if msg == b"ok" and fds:
        return fds[0]
    for fd in fds:
        os.close(fd)
    text = msg.decode("utf-8", "replace")
    if text.startswith("err:FileNotFoundError:"):
        raise FileNotFoundError(errno.ENOENT, text.split(":", 2)[2])
    raise Refused(text.split(":", 2)[2] if text.startswith("err:") else "timed out or died")


def run_as(creds, fn):
    """Run `fn` in a child with `creds`; True if it finished without error."""
    child = os.fork()
    if child == 0:
        try:
            signal.alarm(CHILD_TIMEOUT)
            drop_to(*creds)
            fn()
            os._exit(0)
        except BaseException as e:
            log(f"as uid {creds[0]}: {e}")
            os._exit(1)
    _, status = os.waitpid(child, 0)
    return status == 0


# ── Capabilities and namespaces ──────────────────────────────────────────────


class CapHeader(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]


class CapData(ctypes.Structure):
    _fields_ = [("effective", ctypes.c_uint32), ("permitted", ctypes.c_uint32), ("inheritable", ctypes.c_uint32)]


def drop_caps(*caps):
    """Remove `caps` from this process's effective, permitted and inheritable
    sets (it never execs, so they don't come back)."""
    hdr = CapHeader(0x20080522, 0)  # _LINUX_CAPABILITY_VERSION_3
    data = (CapData * 2)()
    check(libc.capget(ctypes.byref(hdr), data), "capget")
    for c in caps:
        i, bit = divmod(c, 32)
        mask = ~(1 << bit) & 0xFFFFFFFF
        data[i].effective &= mask
        data[i].permitted &= mask
        data[i].inheritable &= mask
    check(libc.capset(ctypes.byref(hdr), data), "capset")


def enter_host_mount_ns():
    """Into PID 1's mount namespace, where systemd resolves BindPaths=, and
    without CAP_SYS_PTRACE (needed only to open it) from then on."""
    fd = os.open("/proc/1/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
    try:
        drop_caps(CAP_SYS_PTRACE)
        os.setns(fd, CLONE_NEWNS)
    finally:
        os.close(fd)


# ── Mounts ───────────────────────────────────────────────────────────────────


def open_tree(fd, recursive):
    flags = OPEN_TREE_CLONE | os.O_CLOEXEC | AT_EMPTY_PATH | (AT_RECURSIVE if recursive else 0)
    return check(libc.syscall(SYS_open_tree, fd, b"", flags), "open_tree")


def mount_setattr(fd, attr_set=0, propagation=0, recursive=True):
    attr = struct.pack("QQQQ", attr_set, 0, propagation, 0)
    buf = ctypes.create_string_buffer(attr, len(attr))
    flags = AT_EMPTY_PATH | (AT_RECURSIVE if recursive else 0)
    check(libc.syscall(SYS_mount_setattr, fd, b"", flags, buf, len(attr)), "mount_setattr")


def move_mount(tree, dst_fd):
    check(
        libc.syscall(SYS_move_mount, tree, b"", dst_fd, b"", MOVE_MOUNT_F_EMPTY_PATH | MOVE_MOUNT_T_EMPTY_PATH),
        "move_mount",
    )


def private_tmpfs(dst_fd):
    """A small root-only tmpfs on `dst_fd`, private: nothing mounted under it
    propagates anywhere."""
    fs = check(libc.syscall(SYS_fsopen, b"tmpfs", FSOPEN_CLOEXEC), "fsopen")
    try:
        for k, v in ((b"mode", b"0700"), (b"size", b"64k"), (b"nr_inodes", b"1024")):
            check(libc.syscall(SYS_fsconfig, fs, FSCONFIG_SET_STRING, k, v, 0), "fsconfig")
        check(libc.syscall(SYS_fsconfig, fs, FSCONFIG_CMD_CREATE, None, None, 0), "fsconfig create")
        mnt = check(
            libc.syscall(SYS_fsmount, fs, FSMOUNT_CLOEXEC, MOUNT_ATTR_NOSUID | MOUNT_ATTR_NODEV | MOUNT_ATTR_NOEXEC),
            "fsmount",
        )
    finally:
        os.close(fs)
    try:
        move_mount(mnt, dst_fd)
        # Attached under a shared /run it became shared too.
        mount_setattr(mnt, propagation=MS_PRIVATE, recursive=False)
    finally:
        os.close(mnt)


def mountpoint(stage_fd, name, is_dir):
    if is_dir:
        os.mkdir(name, 0o700, dir_fd=stage_fd)
    else:
        os.close(os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=stage_fd))
    return os.open(name, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=stage_fd)


NAME = re.compile(r"[a-z]+(-[a-z]+)?[0-9]*")


def check_item(item, user):
    """An item of the stage config, its path canonical and (if it says so)
    under the folder it must be in."""
    if not NAME.fullmatch(item.get("name", "")) or item.get("kind") not in KINDS:
        raise Refused(f"bad item {item!r}")
    path = canonical(item["path"])
    under = item.get("under")
    if under is not None and not path.startswith(canonical(under) + "/"):
        raise Refused(f"{path}: not under {under}")
    return path


def open_item(item, user, path):
    """The item, opened as the user (open_exact); a socket must be the user's."""
    fd = as_user(user_creds(user), lambda: open_exact(path, item["kind"]))
    if item.get("owned") and os.fstat(fd).st_uid != user["uid"]:
        os.close(fd)
        raise Refused(f"{path}: not {user['name']}'s")
    return fd


def stage_items(cfg, project):
    # The project first: a bad one fails the VM before anything is mounted.
    items = list(cfg["items"])
    if cfg.get("cwd"):
        items.insert(0, {"name": "cwd", "path": project_path(project), "kind": "dir", "required": True})
    return items


def stage(cfg, base, key, project=None):
    """Mount every item of `cfg` into base/stage/key (see the module doc)."""
    user = cfg["user"]
    if not key or "/" in key or key in (".", "..") or len(key) > 255:
        raise Refused(f"bad stage key {key!r}")
    items = stage_items(cfg, project)
    for item in items:
        check_item(item, user)
    enter_host_mount_ns()
    bfd = open_trusted(base)
    try:
        try:
            os.mkdir("stage", 0o700, dir_fd=bfd)
        except FileExistsError:
            pass
        sfd = open_trusted(f"{base}/stage")
    finally:
        os.close(bfd)
    try:
        os.mkdir(key, 0o700, dir_fd=sfd)
        kfd = os.open(key, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=sfd)
        try:
            private_tmpfs(kfd)
        finally:
            os.close(kfd)
        kfd = open_trusted(f"{base}/stage/{key}")
    finally:
        os.close(sfd)
    staged = 0
    try:
        for item in items:
            path = item["path"]
            try:
                fd = open_item(item, user, path)
            except FileNotFoundError:
                if item.get("required"):
                    raise Refused(f"{path} doesn't exist")
                continue
            except (Refused, OSError) as e:
                if item.get("required"):
                    raise
                log(f"not sharing {path}: {e}")
                continue
            try:
                tree = open_tree(fd, recursive=True)
                is_dir = stat.S_ISDIR(os.fstat(fd).st_mode)
            finally:
                os.close(fd)
            try:
                attr = MOUNT_ATTR_NOSUID | MOUNT_ATTR_NODEV
                if item.get("ro"):
                    attr |= MOUNT_ATTR_RDONLY
                mount_setattr(tree, attr)
                mp = mountpoint(kfd, item["name"], is_dir)
                try:
                    move_mount(tree, mp)
                finally:
                    os.close(mp)
                staged += 1
            finally:
                os.close(tree)
    finally:
        os.close(kfd)
    return staged


def unstage(base, key):
    """Unmount base/stage/key (everything under it with it) and remove it."""
    enter_host_mount_ns()
    try:
        sfd = open_trusted(f"{base}/stage")
    except FileNotFoundError:
        return
    try:
        target = f"{base}/stage/{key}"
        while True:
            if libc.umount2(os.fsencode(target), MNT_DETACH | UMOUNT_NOFOLLOW) < 0:
                e = ctypes.get_errno()
                if e in (errno.EINVAL, errno.ENOENT):
                    break
                raise OSError(e, f"umount {target}: {os.strerror(e)}")
        try:
            os.rmdir(key, dir_fd=sfd)
        except FileNotFoundError:
            pass
    finally:
        os.close(sfd)


# ── Removing a launch's runtime dir ──────────────────────────────────────────


def rmtree_at(pfd, name, dev):
    """Remove `name` in the directory `pfd`: never following a link, never
    leaving the filesystem `dev`, and refusing a directory swapped mid-way."""
    st = os.lstat(name, dir_fd=pfd)
    if not stat.S_ISDIR(st.st_mode):
        os.unlink(name, dir_fd=pfd)
        return
    if st.st_dev != dev:
        raise OSError(errno.EXDEV, f"{name}: on another filesystem, left alone")
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=pfd)
    try:
        if (os.fstat(fd).st_dev, os.fstat(fd).st_ino) != (st.st_dev, st.st_ino):
            raise OSError(errno.ESTALE, f"{name}: changed while being removed")
        for n in os.listdir(fd):
            rmtree_at(fd, n, dev)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=pfd)


def empty_dir(pfd, name, dev):
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=pfd)
    try:
        for n in os.listdir(fd):
            rmtree_at(fd, n, dev)
    finally:
        os.close(fd)


def remove_entry(pfd, name, dev, as_owner=run_as):
    """Remove `name` from the root-owned directory `pfd`. A directory of
    someone else's is emptied by its owner (as_owner); root then removes it, or,
    if the owner keeps adding to it, takes it back first and empties it itself."""
    try:
        st = os.lstat(name, dir_fd=pfd)
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(st.st_mode):
        os.unlink(name, dir_fd=pfd)
        return
    if st.st_dev != dev:
        raise OSError(errno.EXDEV, f"{name}: on another filesystem, left alone")
    if st.st_uid != os.geteuid():
        as_owner((st.st_uid, st.st_gid, []), lambda: empty_dir(pfd, name, dev))
        try:
            os.rmdir(name, dir_fd=pfd)
            return
        except OSError as e:
            if e.errno not in (errno.ENOTEMPTY, errno.EEXIST):
                raise
        os.chown(name, os.geteuid(), os.getegid(), dir_fd=pfd, follow_symlinks=False)
        rmtree_at(pfd, name, dev)
        return
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=pfd)
    try:
        for n in os.listdir(fd):
            remove_entry(fd, n, dev, as_owner)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=pfd)


def remove_rt(rt, uid=0, base_fd=None, as_owner=run_as):
    parent, name = os.path.split(rt)
    pfd = open_trusted(parent, uid, base_fd)
    try:
        remove_entry(pfd, name, os.fstat(pfd).st_dev, as_owner)
    finally:
        os.close(pfd)


def cleanup(base, key, rt):
    if not rt.startswith(base.rstrip("/") + "/") or "/" in rt[len(base.rstrip("/")) + 1 :]:
        raise Refused(f"{rt}: not a launch dir of {base}")
    # Unmounting happens in the host's namespace, in a child: the removal stays
    # inside this unit's (where only the VM's runtime dir is writable).
    child = os.fork()
    if child == 0:
        try:
            unstage(base, key)
            os._exit(0)
        except BaseException as e:
            log(f"unstaging {base}/stage/{key}: {e}")
            os._exit(1)
    _, status = os.waitpid(child, 0)
    remove_rt(rt)
    return status == 0


# ── The GPU backend's sockets ────────────────────────────────────────────────


def wait_sockets(gpu_fd, names, timeout=10.0):
    deadline = time.monotonic() + timeout
    for n in names:
        while True:
            try:
                if stat.S_ISSOCK(os.lstat(n, dir_fd=gpu_fd).st_mode):
                    break
            except FileNotFoundError:
                pass
            if time.monotonic() >= deadline:
                raise Refused(f"no {n} after {timeout:.0f} s")
            time.sleep(0.1)


def open_socket(dir_fd, name, owner):
    fd = os.open(name, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
    st = os.fstat(fd)
    if not stat.S_ISSOCK(st.st_mode) or st.st_uid != owner:
        os.close(fd)
        raise Refused(f"{name} is not a socket of uid {owner}")
    return fd


def grant_socket(setfacl, fd, user):
    """An ACL for `user` on the socket `fd` (O_PATH, opened without following a
    link): setfacl reaches exactly that inode through /proc/self/fd."""
    subprocess.run([setfacl, "-m", f"u:{user}:rw", "--", f"/proc/self/fd/{fd}"], pass_fds=(fd,), check=True)


def gpu_open(rt, backend, principal, capture, setfacl):
    bpw = pwd.getpwnam(backend)
    rtfd = open_trusted(rt)
    try:
        st = os.lstat("gpu", dir_fd=rtfd)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != bpw.pw_uid:
            raise Refused(f"{rt}/gpu is not the backend's folder")
        names = ["gpu.sock"] + (["inject.sock"] if capture else [])

        def wait():
            gfd = os.open("gpu", os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=rtfd)
            wait_sockets(gfd, names)

        # Inside the backend's folder only as the backend.
        if not run_as((bpw.pw_uid, bpw.pw_gid, []), wait):
            raise Refused("the backend never made its sockets")
        # Root's from here: the backend can't swap what's in it any more.
        os.chown("gpu", 0, 0, dir_fd=rtfd, follow_symlinks=False)
        gfd = os.open("gpu", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=rtfd)
    finally:
        os.close(rtfd)
    try:
        os.fchmod(gfd, 0o711)
        grants = [("gpu.sock", principal)] + ([("inject.sock", capture)] if capture else [])
        for name, user in grants:
            fd = open_socket(gfd, name, bpw.pw_uid)
            try:
                grant_socket(setfacl, fd, user)
            finally:
                os.close(fd)
    finally:
        os.close(gfd)


# ── Cameras ──────────────────────────────────────────────────────────────────


def ctl_socket(rtfd, principal_uid):
    """The VMM's control socket, without following a link: the VMM's folder,
    and a socket of the VMM's uid in it."""
    cfd = os.open("ctl", os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=rtfd)
    try:
        if os.fstat(cfd).st_uid != principal_uid:
            raise Refused("the control folder isn't the VMM's")
        return open_socket(cfd, "crosvm.sock", principal_uid)
    finally:
        os.close(cfd)


def video_devices(sysfs="/sys/bus/usb/devices"):
    """(name, bus, dev, product) for every USB device with a video-class
    interface (class 0e: a webcam, as the host's uvcvideo sees it)."""
    out = []
    for name in sorted(os.listdir(sysfs)):
        if ":" in name or name.startswith("usb"):
            continue
        d = os.path.join(sysfs, name)
        try:
            bus = int(read(f"{d}/busnum"))
            dev = int(read(f"{d}/devnum"))
        except (OSError, ValueError):
            continue
        video = False
        for i in os.listdir(d):
            if i.startswith(name + ":"):
                try:
                    video = video or read(f"{d}/{i}/bInterfaceClass") == "0e"
                except OSError:
                    pass
        if video:
            try:
                product = read(f"{d}/product")
            except OSError:
                product = name
            out.append((name, bus, dev, product))
    return out


def read(path):
    with open(path) as f:
        return f.read().strip()


def camera(action, rt, principal, crosvm):
    puid = pwd.getpwnam(principal).pw_uid
    rtfd = open_trusted(rt)
    try:
        try:
            sock = ctl_socket(rtfd, puid)
        except (FileNotFoundError, Refused) as e:
            if action == "attach":
                raise Refused(f"the VM isn't running ({e})")
            sock = None
        try:
            os.mkdir("camera", 0o700, dir_fd=rtfd)
        except FileExistsError:
            pass
        camfd = open_trusted(f"{rt}/camera")
        try:
            if action == "attach":
                return camera_attach(camfd, sock, crosvm)
            return camera_detach(camfd, sock, crosvm)
        finally:
            os.close(camfd)
            if sock is not None:
                os.close(sock)
    finally:
        os.close(rtfd)


def crosvm_ctl(crosvm, sock, *args):
    r = subprocess.run(
        [crosvm, "usb", *args, f"/proc/self/fd/{sock}"], pass_fds=(sock,), capture_output=True, text=True, timeout=30
    )
    if r.stderr.strip():
        log(f"crosvm usb {args[0]}: {r.stderr.strip()}")
    return r.stdout.strip()


def camera_attach(camfd, sock, crosvm):
    ports = []
    for name, bus, dev, product in video_devices():
        node = f"/dev/bus/usb/{bus:03d}/{dev:03d}"
        out = crosvm_ctl(crosvm, sock, "attach", f"1:1:{bus}:{dev}", node)
        if out.startswith("ok "):
            port = out[3:].split()[0]
            ports.append(f"{port} {name}\n")
            print(f"attached {product} (xHCI port {port})", flush=True)
        else:
            log(f"could not attach {node}: {out}")
    with os.fdopen(os.open("ports", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600, dir_fd=camfd), "w") as f:
        f.writelines(ports)
    if not ports:
        raise Refused("no camera to attach")
    return len(ports)


def camera_detach(camfd, sock, crosvm):
    try:
        with os.fdopen(os.open("ports", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=camfd)) as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return 0
    for line in lines:
        port, _, name = line.partition(" ")
        if not port.isdigit() or not re.fullmatch(r"[0-9]+-[0-9.]+", name):
            continue
        if sock is not None:
            crosvm_ctl(crosvm, sock, "detach", port)
        # Its interfaces were claimed away from the host's drivers: probe again.
        d = "/sys/bus/usb/devices"
        for i in os.listdir(d):
            if i.startswith(name + ":"):
                try:
                    with open("/sys/bus/usb/drivers_probe", "w") as f:
                        f.write(i)
                except OSError:
                    pass
    os.unlink("ports", dir_fd=camfd)
    return len(lines)


# ── Core scheduling ──────────────────────────────────────────────────────────


def main_pid(systemctl, unit):
    r = subprocess.run([systemctl, "show", "-P", "MainPID", "--", unit], capture_output=True, text=True, timeout=10)
    try:
        return int(r.stdout.strip())
    except ValueError:
        return 0


def unit_of(cgroup_text):
    """The unit a /proc/PID/cgroup (v2) names: its cgroup's last component."""
    for line in cgroup_text.splitlines():
        if line.startswith("0::"):
            return line[3:].rstrip("/").rsplit("/", 1)[-1]
    return None


def pinned(pid, unit):
    """A pidfd for `pid`, checked to be in `unit` while the pidfd shows it alive
    (so the number wasn't reused for something else in between)."""
    pfd = os.pidfd_open(pid)
    try:
        if unit_of(read(f"/proc/{pid}/cgroup")) != unit or not alive(pfd):
            raise Refused(f"pid {pid} isn't {unit}'s")
        return pfd
    except BaseException:
        os.close(pfd)
        raise


def alive(pfd):
    return not select.select([pfd], [], [], 0)[0]


def sched_core(cmd, pid, scope, addr=None):
    check(
        libc.prctl(ctypes.c_int(PR_SCHED_CORE), ctypes.c_ulong(cmd), ctypes.c_ulong(pid), ctypes.c_ulong(scope), addr),
        "prctl(PR_SCHED_CORE)",
    )


def cookie(pid):
    c = ctypes.c_ulong(0)
    try:
        sched_core(PR_SCHED_CORE_GET, pid, SCOPE_THREAD, ctypes.byref(c))
    except OSError:
        return 0
    return c.value


def coresched(backend_unit, vmm_unit, systemctl):
    """Give the backend's thread group the cookie `coresched new` made for the
    VMM (the fork's contrib/systemd/nvgpu-vmm-exec `join`). Until then, or if
    this fails, the backend has none: as without the setting."""
    be, vmm = main_pid(systemctl, backend_unit), main_pid(systemctl, vmm_unit)
    if not be or not vmm:
        log(f"{backend_unit} or {vmm_unit} has no main process; the backend keeps no core-scheduling cookie")
        return
    bfd, vfd = pinned(be, backend_unit), pinned(vmm, vmm_unit)
    try:
        for _ in range(200):
            c = cookie(vmm)
            if c:
                sched_core(PR_SCHED_CORE_SHARE_FROM, vmm, SCOPE_THREAD)
                sched_core(PR_SCHED_CORE_SHARE_TO, be, SCOPE_THREAD_GROUP)
                if alive(bfd) and alive(vfd) and cookie(be) == c:
                    print(f"the backend (pid {be}) shares the VMM's core-scheduling cookie {c:#x}", flush=True)
                else:
                    log(f"could not give the backend (pid {be}) the VMM's core-scheduling cookie")
                return
            if not alive(vfd):
                return
            time.sleep(0.05)
        log(f"the VMM (pid {vmm}) has no core-scheduling cookie after 10 s")
    finally:
        os.close(bfd)
        os.close(vfd)


# ── Entry ────────────────────────────────────────────────────────────────────


def main(argv):
    cmd, args = (argv[0], argv[1:]) if argv else ("", [])
    if cmd == "stage" and len(args) in (3, 4):
        with open(args[0]) as f:
            cfg = json.load(f)
        n = stage(cfg, canonical(args[1]), args[2], args[3] if len(args) == 4 else None)
        log(f"{n} path(s) staged in {args[1]}/stage/{args[2]}")
    elif cmd == "cleanup" and len(args) == 3:
        cleanup(canonical(args[0]), args[1], canonical(args[2]))
    elif cmd == "gpu-open" and len(args) in (4, 5):
        gpu_open(canonical(args[0]), args[1], args[2], args[3] if len(args) == 5 else None, args[-1])
    elif cmd == "camera" and len(args) == 4 and args[0] in ("attach", "detach"):
        camera(args[0], canonical(args[1]), args[2], args[3])
    elif cmd == "coresched" and len(args) == 3:
        coresched(*args)
    else:
        print(
            "usage: sbx-vm-root stage CONFIG BASE KEY [DIR] | cleanup BASE KEY RT"
            " | gpu-open RT BACKEND PRINCIPAL [CAPTURE] SETFACL"
            " | camera attach|detach RT PRINCIPAL CROSVM | coresched BACKEND_UNIT VMM_UNIT SYSTEMCTL",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (Refused, OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
        log(str(e))
        sys.exit(1)
