"""sbx-graft: the app guest's storage and bind grafts (lib/vm/guest.nix,
sbx-setup), as root, onto paths the app's own data reaches.

Reads lines "MODE<TAB>SOURCE<TAB>TARGET" (MODE: rw or ro) on stdin and binds
each SOURCE onto TARGET, first making TARGET (and its missing parents: the
user's under the home, root's elsewhere) with SOURCE's type.

The shares hold what the app wrote on earlier boots, and grafts nest (a
persisted ~/.config/app with ~/.config/app/Cache from the cache tier), so a
path may lead through the app's own folders. Both paths are walked from / one
component at a time on held fds, and the mount goes onto the fd the walk ended
on (open_tree + move_mount), as lib/vm/grants.py's agent does. A symlink is
followed only if root owns it and the folder holding it, and nobody else may
replace it there (the system's /etc links, the store's); one the app left
(~/.config/app/Cache -> /nix/store/…-jq/bin) is refused, so the app can't
steer a graft onto a program root later runs or a file root later reads (or
bind a file of root's out to itself).
Nothing is ever grafted onto the store or /run/sbx (root's state).

A missing SOURCE, or a path refused as above, is logged and skipped. Any other
failure is logged, the remaining lines still run, and the exit status is 1.
"""

import errno
import grp
import os
import pwd
import stat
import sys

SYS_open_tree = 428
SYS_move_mount = 429
SYS_mount_setattr = 442
OPEN_TREE_CLONE = 1
AT_EMPTY_PATH = 0x1000
MOVE_MOUNT_F_EMPTY_PATH = 0x4
MOVE_MOUNT_T_EMPTY_PATH = 0x40
MOUNT_ATTR_RDONLY = 0x1

DIR = os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
ANY = os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC
MAX_LINKS = 40
FORBIDDEN = ("/nix", "/run/sbx")
_libc = None


class Skip(Exception):
    pass


def log(msg):
    print(f"sbx-graft: {msg}", file=sys.stderr, flush=True)


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
    return path.startswith("/") and not path.startswith("//") and "\0" not in path and os.path.normpath(path) == path


def under(path, top):
    return path == top or path.startswith(top + "/")


def trusted_link(dfd, name):
    """Root's link in a folder of root's that only root may change it in:
    writable by root alone, or sticky (the store, 1775 root:nixbld)."""
    st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
    d = os.fstat(dfd)
    return st.st_uid == 0 and d.st_uid == 0 and (not d.st_mode & 0o022 or bool(d.st_mode & stat.S_ISVTX))


def make(dfd, name, kind, here, owner):
    """Create `name` in `dfd` (a folder, or with kind "file" an empty file) and
    return an fd for it; the user's (by fd, never by name) under the home."""
    home, uid, gid = owner
    if kind == "file":
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dfd)
    else:
        os.mkdir(name, 0o700 if kind == "leaf" else 0o755, dir_fd=dfd)
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dfd)
    if under(here, home) and here != home:
        os.fchown(fd, uid, gid)
    return fd


def walk(path, kind=None, owner=None):
    """(fd, real path) of `path`, walked as the module says. `kind` (None: it
    must exist): "dir" or "file", what to create the last component as when
    it's missing; missing parents are then made too."""
    links = 0
    while True:
        parts = [p for p in path.split("/") if p]
        fd = os.open("/", DIR)
        here = ""
        try:
            for i, part in enumerate(parts):
                last = i == len(parts) - 1
                nxt = here + "/" + part
                try:
                    st = os.stat(part, dir_fd=fd, follow_symlinks=False)
                except FileNotFoundError:
                    if kind is None:
                        raise FileNotFoundError(errno.ENOENT, "missing", path)
                    nfd = make(fd, part, (kind if kind == "file" else "leaf") if last else "dir", nxt, owner)
                else:
                    if stat.S_ISLNK(st.st_mode):
                        if not trusted_link(fd, part):
                            raise Skip(f"{nxt} is a symlink (not root's): {path} refused")
                        links += 1
                        if links > MAX_LINKS:
                            raise Skip(f"{path}: too many symlinks")
                        target = os.readlink(part, dir_fd=fd)
                        rest = "/".join(parts[i + 1 :])
                        path = os.path.normpath(os.path.join(here or "/", target, rest))
                        break
                    try:
                        nfd = os.open(part, ANY if last else DIR, dir_fd=fd)
                    except NotADirectoryError:
                        raise Skip(f"{nxt} is not a folder: {path} refused")
                    except OSError as e:
                        if e.errno == errno.ELOOP:
                            raise Skip(f"{nxt} changed under the walk: {path} refused")
                        raise
                os.close(fd)
                fd = nfd
                here = nxt
            else:
                return fd, here or "/"
            os.close(fd)
        except BaseException:
            os.close(fd)
            raise


def bind(src, dst, ro):
    import ctypes
    import struct

    c = libc()
    tree = check(c.syscall(SYS_open_tree, src, b"", OPEN_TREE_CLONE | os.O_CLOEXEC | AT_EMPTY_PATH), "open_tree")
    try:
        if ro:
            attr = struct.pack("QQQQ", MOUNT_ATTR_RDONLY, 0, 0, 0)
            buf = ctypes.create_string_buffer(attr, len(attr))
            check(c.syscall(SYS_mount_setattr, tree, b"", AT_EMPTY_PATH, buf, len(attr)), "mount_setattr")
        check(
            c.syscall(SYS_move_mount, tree, b"", dst, b"", MOVE_MOUNT_F_EMPTY_PATH | MOVE_MOUNT_T_EMPTY_PATH),
            "move_mount",
        )
    finally:
        os.close(tree)


def graft(mode, src, dst, owner):
    if mode not in ("rw", "ro"):
        raise ValueError(f"bad mode {mode!r}")
    for p in (src, dst):
        if not canonical(p):
            raise ValueError(f"{p!r}: not a canonical absolute path")
    if any(under(dst, top) for top in FORBIDDEN) or dst == "/":
        raise Skip(f"{dst}: refused")
    try:
        sfd, _ = walk(src)
    except FileNotFoundError:
        raise Skip(f"missing share entry {src}, skipped")
    try:
        sm = os.fstat(sfd).st_mode
        if stat.S_ISDIR(sm):
            kind = "dir"
        elif stat.S_ISREG(sm):
            kind = "file"
        else:
            raise Skip(f"{src} is neither a folder nor a file, skipped")
        dfd, where = walk(dst, kind, owner)
        try:
            if any(under(where, top) for top in FORBIDDEN) or where == "/":
                raise Skip(f"{dst} leads to {where}: refused")
            dm = os.fstat(dfd).st_mode
            if (kind == "dir") != stat.S_ISDIR(dm) or (kind == "file" and not stat.S_ISREG(dm)):
                raise Skip(f"{dst} exists as another type than {src}: skipped")
            bind(sfd, dfd, mode == "ro")
        finally:
            os.close(dfd)
    finally:
        os.close(sfd)


def main():
    if len(sys.argv) != 4:
        print("usage: sbx-graft HOME USER GROUP < lines", file=sys.stderr)
        return 2
    home, user, group = sys.argv[1:]
    owner = (home, pwd.getpwnam(user).pw_uid, grp.getgrnam(group).gr_gid)
    status = 0
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        try:
            mode, src, dst = line.split("\t")
            graft(mode, src, dst, owner)
        except Skip as e:
            log(str(e))
        except Exception as e:
            log(f"{line!r}: {e}")
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
