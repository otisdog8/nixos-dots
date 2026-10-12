# Race-free bind mounts for the systemd backend's root setup phase.
#
# The runScript runs as ROOT inside the unit's private mount namespace and binds
# paths that live in directories an UNPRIVILEGED principal controls: jrt's runtime
# dir (relay sources) and the app's own home (graft targets). A check-then-use
# shell sequence (`[ -L p ]`, then `mkdir -p`/`chown`/`mount --bind p`) re-resolves
# the path at every step, so a concurrent process can swap a checked component for
# a symlink and redirect root. This helper never re-resolves a path:
#   - every path is walked one component at a time with O_NOFOLLOW, each step
#     relative to the directory fd already held (a symlink anywhere → refuse);
#   - type/owner checks are done with fstat() on the held fd;
#   - the bind is mount("/proc/self/fd/<src>", "/proc/self/fd/<dst>"), which the
#     kernel resolves to exactly the inodes that were checked.
#
# And root does no work in a directory it doesn't own. Each step inside a
# directory owned by another uid (opening the next component, mkdir, creating,
# unlinking) runs in a forked child that has dropped to that directory's owner
# (fstat of the held fd), works on the held fd, and hands back an O_PATH fd for
# what it opened (SCM_RIGHTS). So every permission check in those directories is
# the owner's, and root needs no CAP_DAC_* at all. Root itself only walks
# root-owned directories, mounts, and chowns a fd it holds (a graft's
# intermediates, for a dedicated uid). A directory writable by others (or a
# root-owned one writable by its group) is refused: its entries aren't its
# owner's to vouch for.
#
# Usage:
#   relay <src> <dst> <S|d> <owner-uid>
#       Bind jrt's socket (S) or directory (d) <src> onto the existing mountpoint
#       <dst>. <src> must be owned by <owner-uid>. Exit 1 on refusal.
#   graft <stash> <home> <relpath> <dir|file> [<chown-user>]
#       Create <home>/<relpath> (missing parents 0755, made by the owner of the
#       directory they're made in; with <chown-user>, every parent is then owned
#       by that user, so a dedicated uid can traverse them) and bind the stash
#       leaf onto it. Exit 1 on refusal.
import ctypes
import errno
import os
import pwd
import socket
import stat
import sys

MS_BIND = 4096
PR_SET_DUMPABLE = 4
PROG = "sandbox-mount-helper"

libc = ctypes.CDLL(None, use_errno=True)
libc.mount.argtypes = [
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_ulong,
    ctypes.c_void_p,
]

# Indirection for the tests (which can't be root): who "we" are when deciding
# whether a directory's owner is someone else.
_euid = os.geteuid


class Refuse(Exception):
    pass


def comps(path):
    return [c for c in path.split("/") if c not in ("", ".")]


def check_dir(st, name):
    """The directory holding `name` (st) may be worked in: not writable by others."""
    if st.st_mode & stat.S_IWOTH or (st.st_uid == 0 and st.st_mode & stat.S_IWGRP):
        raise Refuse(f"the directory holding '{name}' is writable by others")


# ── Working as a directory's owner ───────────────────────────────────────────


def close_except(keep):
    lo = 3
    for fd in sorted(keep):
        if fd >= lo:
            os.closerange(lo, fd)
            lo = fd + 1
    os.closerange(lo, 1 << 20)


def drop(uid, gid):
    if os.geteuid() == 0:
        os.setgroups([])
    os.setresgid(gid, gid, gid)
    os.setresuid(uid, uid, uid)
    # The uid change already made us undumpable (fs.suid_dumpable = 0), so the
    # owner can't ptrace this process or reach its fds through /proc. Make sure.
    libc.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0)


def in_child(uid, gid, dir_fd, fn, *args):
    """Run fn(dir_fd, *args), which returns an fd (or None), in a child that has
    dropped to uid/gid, and return the fd it hands back. Its Refuse and OSError
    (with the errno, so FileNotFoundError stays one) are raised here."""
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    pid = os.fork()
    if pid == 0:
        try:
            a.close()
            close_except({dir_fd, b.fileno(), 0, 1, 2})
            drop(uid, gid)
            fd = fn(dir_fd, *args)
            socket.send_fds(b, [b"ok"], [] if fd is None else [fd])
            os._exit(0)
        except Refuse as e:
            msg = b"R" + str(e).encode()
        except OSError as e:
            msg = b"E%d:" % (e.errno or 0) + (e.strerror or str(e)).encode()
        except BaseException as e:
            msg = b"X" + repr(e).encode()
        try:
            b.send(msg[:1000])
        finally:
            os._exit(1)
    b.close()
    try:
        msg, fds, _flags, _addr = socket.recv_fds(a, 1024, 1)
    finally:
        a.close()
        os.waitpid(pid, 0)
    if msg == b"ok":
        return fds[0] if fds else None
    for fd in fds:
        os.close(fd)
    text = msg[1:].decode("utf-8", "replace")
    if msg[:1] == b"R":
        raise Refuse(text)
    if msg[:1] == b"E":
        code, _, what = text.partition(":")
        raise OSError(int(code), what)
    raise Refuse(f"helper child failed: {text or 'no reply'}")


def as_owner(dir_fd, fn, name, *args):
    """fn(dir_fd, name, *args), as the owner of the directory dir_fd holds."""
    st = os.fstat(dir_fd)
    check_dir(st, name)
    if st.st_uid == _euid():
        return fn(dir_fd, name, *args)
    try:
        gid = pwd.getpwuid(st.st_uid).pw_gid
    except KeyError:
        gid = st.st_gid
    return in_child(st.st_uid, gid, dir_fd, fn, name, *args)


# ── Steps (run as the directory's owner) ─────────────────────────────────────


def open_dir_at(parent, name):
    try:
        return os.open(
            name, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent
        )
    except OSError as e:
        if e.errno in (errno.ELOOP, errno.ENOTDIR):
            raise Refuse(f"'{name}' is a symlink or not a directory")
        raise


def open_or_make_dir(parent, name):
    try:
        return open_dir_at(parent, name)
    except FileNotFoundError:
        os.mkdir(name, 0o755, dir_fd=parent)
        return open_dir_at(parent, name)


def open_leaf_fd(parent, name):
    fd = os.open(name, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    if stat.S_ISLNK(os.fstat(fd).st_mode):
        os.close(fd)
        raise Refuse(f"'{name}' is a symlink")
    return fd


def make_graft_leaf(parent, leaf, kind):
    """The graft's mountpoint `leaf` in `parent`, created if missing; a stale
    entry of the wrong type is replaced."""
    try:
        st = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        st = None
    if st is not None and stat.S_ISLNK(st.st_mode):
        raise Refuse(f"graft target '{leaf}' is a symlink")
    if kind == "dir":
        # Self-heal a stale non-directory left by a type change.
        if st is not None and not stat.S_ISDIR(st.st_mode):
            os.unlink(leaf, dir_fd=parent)
            st = None
        if st is None:
            os.mkdir(leaf, 0o755, dir_fd=parent)
    else:
        # Self-heal a stale (empty) directory mountpoint; rmdir fails if non-empty.
        if st is not None and not stat.S_ISREG(st.st_mode):
            os.rmdir(leaf, dir_fd=parent)
            st = None
        if st is None:
            os.close(
                os.open(
                    leaf,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                    0o644,
                    dir_fd=parent,
                )
            )
    return open_leaf_fd(parent, leaf)


# ── Walking (root, handing each step to the directory's owner) ───────────────


def open_root(root):
    return os.open(root, os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC)


def step_dir(parent, name, make=False):
    fd = as_owner(parent, open_or_make_dir if make else open_dir_at, name)
    if not stat.S_ISDIR(os.fstat(fd).st_mode):
        os.close(fd)
        raise Refuse(f"'{name}' is not a directory")
    return fd


def open_leaf(parent, name):
    fd = as_owner(parent, open_leaf_fd, name)
    st = os.fstat(fd)
    if stat.S_ISLNK(st.st_mode):
        os.close(fd)
        raise Refuse(f"'{name}' is a symlink")
    return fd, st


def walk(path, root="/"):
    """Open every component of absolute `path` as a directory, never following
    symlinks. (`root`: where "/" is; the tests' stand-in for the real one.)"""
    if not path.startswith("/"):
        raise Refuse(f"'{path}' is not absolute")
    if ".." in comps(path):
        raise Refuse(f"'{path}' contains '..'")
    fd = open_root(root)
    for c in comps(path):
        try:
            nfd = step_dir(fd, c)
        finally:
            os.close(fd)
        fd = nfd
    return fd


def open_path(path, root="/"):
    """Open `path` (any type) with no symlink in any component."""
    parts = comps(path)
    if not parts:
        raise Refuse("empty path")
    parent = walk("/" + "/".join(parts[:-1]), root)
    try:
        return open_leaf(parent, parts[-1])
    finally:
        os.close(parent)


def chown_fd(fd, uid):
    # /proc/self/fd/N resolves to exactly the held inode (never a swapped name).
    os.chown(f"/proc/self/fd/{fd}", uid, -1)


def bind(src_fd, dst_fd):
    rc = libc.mount(
        f"/proc/self/fd/{src_fd}".encode(),
        f"/proc/self/fd/{dst_fd}".encode(),
        None,
        MS_BIND,
        None,
    )
    if rc != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))


def relay_fds(src, dst, kind, owner, root="/"):
    want = stat.S_ISSOCK if kind == "S" else stat.S_ISDIR
    sfd, sst = open_path(src, root)
    if not want(sst.st_mode):
        raise Refuse(f"relay source '{src}' has the wrong type")
    if sst.st_uid != int(owner):
        raise Refuse(f"relay source '{src}' is not owned by uid {owner}")
    dfd, dst_st = open_path(dst, root)
    if kind == "S" and not stat.S_ISREG(dst_st.st_mode):
        raise Refuse(f"relay target '{dst}' is not a regular file")
    if kind == "d" and not stat.S_ISDIR(dst_st.st_mode):
        raise Refuse(f"relay target '{dst}' is not a directory")
    return sfd, dfd


def relay(src, dst, kind, owner):
    bind(*relay_fds(src, dst, kind, owner))


def graft_fds(stash, home, relpath, kind, chown_user=None, root="/"):
    parts = comps(relpath)
    if not parts or ".." in parts:
        raise Refuse(f"bad graft path '{relpath}'")
    chown_uid = pwd.getpwnam(chown_user).pw_uid if chown_user else None

    # Source: the stash leaf. Its parents are root-owned, but walk it the same way.
    sfd, sst = open_path(stash, root)
    if kind == "file" and not stat.S_ISREG(sst.st_mode):
        raise Refuse(f"stash '{stash}' is not a file")
    if kind == "dir" and not stat.S_ISDIR(sst.st_mode):
        raise Refuse(f"stash '{stash}' is not a directory")

    # Target parents: created as needed (by the owner of the directory each is
    # made in) under the held home fd. Pre-existing intermediates owned by
    # someone else (e.g. left 0700 by an older owner inside a mounted parent
    # stash) are chowned to the app uid, so a dedicated app can traverse them —
    # root, on the fd its owner's child opened.
    parent = walk(home, root)
    for c in parts[:-1]:
        try:
            nfd = step_dir(parent, c, make=True)
        finally:
            os.close(parent)
        parent = nfd
        if chown_uid is not None and os.fstat(parent).st_uid != chown_uid:
            chown_fd(parent, chown_uid)

    try:
        dfd = as_owner(parent, make_graft_leaf, parts[-1], kind)
    finally:
        os.close(parent)
    dst_st = os.fstat(dfd)
    if kind == "dir" and not stat.S_ISDIR(dst_st.st_mode):
        raise Refuse(f"graft target '{relpath}' is not a directory")
    if kind == "file" and not stat.S_ISREG(dst_st.st_mode):
        raise Refuse(f"graft target '{relpath}' is not a file")
    return sfd, dfd


def graft(stash, home, relpath, kind, chown_user=None):
    bind(*graft_fds(stash, home, relpath, kind, chown_user))


def main(argv):
    try:
        if len(argv) == 5 and argv[0] == "relay" and argv[3] in ("S", "d"):
            relay(*argv[1:])
        elif len(argv) in (5, 6) and argv[0] == "graft" and argv[4] in ("dir", "file"):
            graft(*argv[1:])
        else:
            print(f"{PROG}: bad usage: {argv}", file=sys.stderr)
            return 2
    except (Refuse, OSError) as e:
        print(f"{PROG}: {argv[0]} {argv[1]}: refusing: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
