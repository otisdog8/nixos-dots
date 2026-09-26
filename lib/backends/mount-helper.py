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
#   - missing directories are created with mkdirat() on the held parent fd;
#   - type/owner checks are done with fstat() on the held fd;
#   - the bind is mount("/proc/self/fd/<src>", "/proc/self/fd/<dst>"), which the
#     kernel resolves to exactly the inodes that were checked.
#
# Usage:
#   relay <src> <dst> <S|d> <owner-uid>
#       Bind jrt's socket (S) or directory (d) <src> onto the existing mountpoint
#       <dst>. <src> must be owned by <owner-uid>. Exit 1 on refusal.
#   graft <stash> <home> <relpath> <dir|file> [<chown-user>]
#       Create <home>/<relpath> (parents root-created 0755, optionally chowned to
#       <chown-user> so a dedicated uid can traverse them) and bind the stash leaf
#       onto it. Exit 1 on refusal.
import ctypes
import errno
import os
import pwd
import stat
import sys

MS_BIND = 4096
PROG = "sandbox-mount-helper"

libc = ctypes.CDLL(None, use_errno=True)
libc.mount.argtypes = [
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_ulong,
    ctypes.c_void_p,
]


class Refuse(Exception):
    pass


def comps(path):
    return [c for c in path.split("/") if c not in ("", ".")]


def open_dir_at(parent, name):
    try:
        return os.open(
            name, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent
        )
    except OSError as e:
        if e.errno in (errno.ELOOP, errno.ENOTDIR):
            raise Refuse(f"'{name}' is a symlink or not a directory")
        raise


def walk(path):
    """Open every component of absolute `path` as a directory, never following
    symlinks."""
    if not path.startswith("/"):
        raise Refuse(f"'{path}' is not absolute")
    if ".." in comps(path):
        raise Refuse(f"'{path}' contains '..'")
    fd = os.open("/", os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC)
    for c in comps(path):
        try:
            nfd = open_dir_at(fd, c)
        finally:
            os.close(fd)
        fd = nfd
    return fd


def chown_fd(fd, uid):
    # /proc/self/fd/N resolves to exactly the held inode (never a swapped name).
    os.chown(f"/proc/self/fd/{fd}", uid, -1)


def open_leaf(parent, name):
    fd = os.open(name, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    st = os.fstat(fd)
    if stat.S_ISLNK(st.st_mode):
        os.close(fd)
        raise Refuse(f"'{name}' is a symlink")
    return fd, st


def open_path(path):
    """Open `path` (any type) with no symlink in any component."""
    parts = comps(path)
    if not parts:
        raise Refuse("empty path")
    parent = walk("/" + "/".join(parts[:-1]))
    try:
        return open_leaf(parent, parts[-1])
    finally:
        os.close(parent)


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


def relay(src, dst, kind, owner):
    want = stat.S_ISSOCK if kind == "S" else stat.S_ISDIR
    sfd, sst = open_path(src)
    if not want(sst.st_mode):
        raise Refuse(f"relay source '{src}' has the wrong type")
    if sst.st_uid != int(owner):
        raise Refuse(f"relay source '{src}' is not owned by uid {owner}")
    dfd, dst_st = open_path(dst)
    if kind == "S" and not stat.S_ISREG(dst_st.st_mode):
        raise Refuse(f"relay target '{dst}' is not a regular file")
    if kind == "d" and not stat.S_ISDIR(dst_st.st_mode):
        raise Refuse(f"relay target '{dst}' is not a directory")
    bind(sfd, dfd)


def graft(stash, home, relpath, kind, chown_user=None):
    parts = comps(relpath)
    if not parts or ".." in parts:
        raise Refuse(f"bad graft path '{relpath}'")
    chown_uid = pwd.getpwnam(chown_user).pw_uid if chown_user else None

    # Source: the stash leaf. Its parents are root-owned, but walk it the same way.
    sfd, sst = open_path(stash)
    if kind == "file" and not stat.S_ISREG(sst.st_mode):
        raise Refuse(f"stash '{stash}' is not a file")
    if kind == "dir" and not stat.S_ISDIR(sst.st_mode):
        raise Refuse(f"stash '{stash}' is not a directory")

    # Target parents: created as needed under the held home fd. Pre-existing
    # intermediates (e.g. left 0700 by an older owner inside a mounted parent
    # stash) are chowned to the app uid too, so a dedicated app can traverse them.
    parent = walk(home)
    for c in parts[:-1]:
        try:
            nfd = open_dir_at(parent, c)
        except FileNotFoundError:
            os.mkdir(c, 0o755, dir_fd=parent)
            nfd = open_dir_at(parent, c)
        if chown_uid is not None:
            chown_fd(nfd, chown_uid)
        os.close(parent)
        parent = nfd

    leaf = parts[-1]
    try:
        st = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        st = None
    if st is not None and stat.S_ISLNK(st.st_mode):
        raise Refuse(f"graft target '{relpath}' is a symlink")
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
    dfd, dst_st = open_leaf(parent, leaf)
    if kind == "dir" and not stat.S_ISDIR(dst_st.st_mode):
        raise Refuse(f"graft target '{relpath}' is not a directory")
    if kind == "file" and not stat.S_ISREG(dst_st.st_mode):
        raise Refuse(f"graft target '{relpath}' is not a file")
    bind(sfd, dfd)


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
