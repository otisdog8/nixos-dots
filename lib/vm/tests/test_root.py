"""Unprivileged tests for lib/vm/root.py (sbx-vm-root): the path checks root
relies on (root-only chains, opening exactly the path asked for, never through
a symlink, the store-link exception, per-project path rules, stage items), the
fd-passing child, the removal of a launch's runtime dir (never following a
link or leaving the filesystem, other owners' folders emptied as their owner),
socket checks, the cgroup and sysfs parsing. The mounts, setns, ownership
changes and prctl need root and real VMs.

  python3 -m unittest discover -s lib/vm/tests -p 'test_root.py'
"""

import errno
import importlib.util
import os
import socket
import stat
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("vmroot", os.path.join(HERE, "..", "root.py"))
vmroot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vmroot)
vmroot.log = lambda msg: None


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        # realpath: open_exact compares against the kernel's name for it.
        self.d = os.path.realpath(self.tmp.name)
        os.chmod(self.d, 0o700)

    def tearDown(self):
        self.tmp.cleanup()

    def p(self, *parts):
        return os.path.join(self.d, *parts)


class Canonical(unittest.TestCase):
    def test_accepts(self):
        for p in ("/", "/home/u", "/home/u/a b", "/x/.hidden"):
            self.assertEqual(vmroot.canonical(p), p)

    def test_refuses(self):
        for p in ("", "rel", "//x", "/x/", "/x/./y", "/x/../y", "/x//y", "/x\0", None, 3):
            with self.assertRaises(vmroot.Refused, msg=repr(p)):
                vmroot.canonical(p)

    def test_project_path(self):
        self.assertEqual(vmroot.project_path("/home/u/my proj,v=1@x+y~"), "/home/u/my proj,v=1@x+y~")
        for p in ("/", "/home/u/$(x)", "/home/u/a\nb", "/home/u/../etc", "relative", "/home/u/a:b"):
            with self.assertRaises(vmroot.Refused, msg=repr(p)):
                vmroot.project_path(p)


class Trusted(Tmp):
    def open(self, rel):
        base = os.open(self.d, os.O_PATH | os.O_DIRECTORY)
        try:
            return vmroot.open_trusted(rel, uid=os.getuid(), base_fd=base)
        finally:
            os.close(base)

    def test_chain(self):
        os.makedirs(self.p("a", "b"), mode=0o711)
        fd = self.open("a/b")
        self.assertTrue(stat.S_ISDIR(os.fstat(fd).st_mode))
        os.close(fd)

    def test_symlink_in_chain(self):
        os.makedirs(self.p("real"))
        os.symlink("real", self.p("link"))
        with self.assertRaises(vmroot.Refused):
            self.open("link")

    def test_writable_by_others(self):
        os.makedirs(self.p("a", "b"))
        os.chmod(self.p("a"), 0o777)
        with self.assertRaises(vmroot.Refused):
            self.open("a/b")
        os.chmod(self.p("a"), 0o775)
        with self.assertRaises(vmroot.Refused):
            self.open("a/b")

    def test_wrong_owner(self):
        os.makedirs(self.p("a"))
        base = os.open(self.d, os.O_PATH | os.O_DIRECTORY)
        try:
            with self.assertRaises(vmroot.Refused):
                vmroot.open_trusted("a", uid=os.getuid() + 1, base_fd=base)
        finally:
            os.close(base)

    def test_not_a_dir(self):
        open(self.p("f"), "w").close()
        with self.assertRaises(vmroot.Refused):
            self.open("f")

    def test_dotdot(self):
        os.makedirs(self.p("a"))
        with self.assertRaises(vmroot.Refused):
            self.open("a/..")


class Exact(Tmp):
    def test_dir_and_file(self):
        os.makedirs(self.p("a", "b"))
        open(self.p("a", "f"), "w").close()
        for path, kind in ((self.p("a", "b"), "dir"), (self.p("a", "f"), "file"), (self.p("a", "f"), "any"), (self.p("a", "b"), "any")):
            fd = vmroot.open_exact(path, kind)
            self.assertEqual(os.readlink(f"/proc/self/fd/{fd}"), path)
            os.close(fd)

    def test_wrong_kind(self):
        os.makedirs(self.p("a"))
        open(self.p("f"), "w").close()
        with self.assertRaises(vmroot.Refused):
            vmroot.open_exact(self.p("f"), "dir")
        with self.assertRaises(vmroot.Refused):
            vmroot.open_exact(self.p("a"), "file")
        with self.assertRaises(vmroot.Refused):
            vmroot.open_exact(self.p("a"), "socket")
        os.mkfifo(self.p("fifo"))
        with self.assertRaises(vmroot.Refused):
            vmroot.open_exact(self.p("fifo"), "any")

    def test_missing(self):
        with self.assertRaises(FileNotFoundError):
            vmroot.open_exact(self.p("nope"), "dir")

    def test_symlink_anywhere(self):
        os.makedirs(self.p("real", "sub"))
        os.symlink(self.p("real"), self.p("link"))
        for path, kind in ((self.p("link"), "dir"), (self.p("link", "sub"), "dir"), (self.p("link", "sub"), "any")):
            with self.assertRaises(vmroot.Refused, msg=path):
                vmroot.open_exact(path, kind)

    def test_link_out_of_store(self):
        open(self.p("secret"), "w").close()
        os.symlink(self.p("secret"), self.p("gitconfig"))
        with self.assertRaises(vmroot.Refused):
            vmroot.open_exact(self.p("gitconfig"), "file")

    def test_link_into_store(self):
        store = self.p("store") + "/"
        os.makedirs(self.p("store", "hm-files"))
        with open(self.p("store", "x-gitconfig"), "w") as f:
            f.write("[user]\n")
        # home-manager: ~/.gitconfig → store/hm-files/.gitconfig → store/x-gitconfig
        os.symlink(self.p("store", "x-gitconfig"), self.p("store", "hm-files", ".gitconfig"))
        os.makedirs(self.p("home"))
        os.symlink(self.p("store", "hm-files", ".gitconfig"), self.p("home", ".gitconfig"))
        with mock.patch.object(vmroot, "STORE", store):
            fd = vmroot.open_exact(self.p("home", ".gitconfig"), "file")
            self.assertEqual(os.readlink(f"/proc/self/fd/{fd}"), self.p("store", "x-gitconfig"))
            os.close(fd)
            # Never for a folder entry, nor through a link in the parent.
            with self.assertRaises(vmroot.Refused):
                vmroot.open_exact(self.p("home", ".gitconfig"), "dir")
            os.symlink(self.p("home"), self.p("homelink"))
            with self.assertRaises(vmroot.Refused):
                vmroot.open_exact(self.p("homelink", ".gitconfig"), "file")
            # A store link that leaves the store again.
            open(self.p("outside"), "w").close()
            os.symlink(self.p("outside"), self.p("store", "escape"))
            os.symlink(self.p("store", "escape"), self.p("home", "esc"))
            with self.assertRaises(vmroot.Refused):
                vmroot.open_exact(self.p("home", "esc"), "file")

    def test_socket(self):
        s = socket.socket(socket.AF_UNIX)
        s.bind(self.p("s.sock"))
        try:
            fd = vmroot.open_exact(self.p("s.sock"), "socket")
            os.close(fd)
            with self.assertRaises(vmroot.Refused):
                vmroot.open_exact(self.p("s.sock"), "any")
        finally:
            s.close()


class Items(unittest.TestCase):
    user = {"name": "u", "uid": 1000, "gid": 100, "home": "/home/u"}

    def test_check(self):
        ok = {"name": "e0", "path": "/home/u/.config/x", "kind": "dir", "under": "/home/u"}
        self.assertEqual(vmroot.check_item(ok, self.user), "/home/u/.config/x")
        for bad in (
            dict(ok, path="/home/user2/x"),
            dict(ok, path="/home/u"),
            dict(ok, path="/home/u/../etc"),
            dict(ok, name="../x"),
            dict(ok, name=""),
            dict(ok, kind="device"),
        ):
            with self.assertRaises(vmroot.Refused, msg=repr(bad)):
                vmroot.check_item(bad, self.user)
        self.assertEqual(vmroot.check_item(dict(ok, path="/etc/x", under=None), self.user), "/etc/x")
        self.assertEqual(vmroot.check_item(dict(ok, name="relay-pulse"), self.user), "/home/u/.config/x")

    def test_cwd_item(self):
        cfg = {"user": self.user, "items": [], "cwd": True}
        items = vmroot.stage_items(cfg, "/home/u/proj")
        self.assertEqual(items[0], {"name": "cwd", "path": "/home/u/proj", "kind": "dir", "required": True})
        with self.assertRaises(vmroot.Refused):
            vmroot.stage_items(cfg, "/")
        with self.assertRaises(vmroot.Refused):
            vmroot.stage_items(cfg, None)
        self.assertEqual(vmroot.stage_items({"user": self.user, "items": []}, None), [])

    def test_refused_before_any_mount(self):
        cfg = {"user": self.user, "items": [], "cwd": True}
        with mock.patch.object(vmroot, "enter_host_mount_ns", side_effect=AssertionError("entered")):
            for key, project in (("a/b", "/home/u/p"), ("..", "/home/u/p"), ("k", "/"), ("k", "/home/u/p/../q")):
                with self.assertRaises(vmroot.Refused, msg=(key, project)):
                    vmroot.stage(cfg, "/run/sandbox-vm/x", key, project)
            bad = {"user": self.user, "items": [{"name": "e0", "path": "/root/x", "kind": "dir", "under": "/home/u"}]}
            with self.assertRaises(vmroot.Refused):
                vmroot.stage(bad, "/run/sandbox-vm/x", "main")


class Child(Tmp):
    def setUp(self):
        super().setUp()
        self.patch = mock.patch.object(vmroot, "drop_to", lambda *a: None)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        super().tearDown()

    creds = (os.getuid(), os.getgid(), [])

    def test_fd_comes_back(self):
        os.makedirs(self.p("a"))
        fd = vmroot.as_user(self.creds, lambda: vmroot.open_exact(self.p("a"), "dir"))
        self.assertEqual(os.readlink(f"/proc/self/fd/{fd}"), self.p("a"))
        os.close(fd)

    def test_errors_come_back(self):
        with self.assertRaises(FileNotFoundError):
            vmroot.as_user(self.creds, lambda: vmroot.open_exact(self.p("nope"), "dir"))
        os.symlink("/etc", self.p("l"))
        with self.assertRaises(vmroot.Refused) as cm:
            vmroot.as_user(self.creds, lambda: vmroot.open_exact(self.p("l"), "dir"))
        self.assertIn("symlink", str(cm.exception))

    def test_child_dies(self):
        with self.assertRaises(vmroot.Refused):
            vmroot.as_user(self.creds, lambda: os._exit(3))

    def test_run_as(self):
        self.assertTrue(vmroot.run_as(self.creds, lambda: None))
        self.assertFalse(vmroot.run_as(self.creds, lambda: 1 / 0))


class Removal(Tmp):
    def tree(self):
        rt = self.p("base", "id")
        os.makedirs(self.p("base", "id", "meta"))
        os.makedirs(self.p("base", "id", "grants", "view", "deep"))
        open(self.p("base", "id", "meta", "cid"), "w").close()
        os.makedirs(self.p("outside"))
        open(self.p("outside", "keep"), "w").close()
        # Links the VM's users might plant: never followed.
        os.symlink(self.p("outside"), self.p("base", "id", "grants", "view", "link"))
        os.symlink(self.p("outside", "keep"), self.p("base", "id", "meta", "flink"))
        return rt

    def base_fd(self):
        return os.open(self.d, os.O_PATH | os.O_DIRECTORY)

    def test_removes_without_following(self):
        self.tree()
        b = self.base_fd()
        try:
            vmroot.remove_rt("base/id", uid=os.getuid(), base_fd=b)
        finally:
            os.close(b)
        self.assertFalse(os.path.exists(self.p("base", "id")))
        self.assertTrue(os.path.exists(self.p("outside", "keep")))

    def test_missing_is_fine(self):
        os.makedirs(self.p("base"))
        b = self.base_fd()
        try:
            vmroot.remove_rt("base/id", uid=os.getuid(), base_fd=b)
        finally:
            os.close(b)

    def test_other_owner_emptied_as_owner(self):
        self.tree()
        calls = []

        def as_owner(creds, fn):
            calls.append(creds)
            fn()
            return True

        b = self.base_fd()
        me = os.geteuid()
        try:
            # Everything looks like someone else's from "root" (uid me+1).
            with mock.patch.object(os, "geteuid", lambda: me + 1):
                vmroot.remove_rt("base/id", uid=me, base_fd=b, as_owner=as_owner)
        finally:
            os.close(b)
        self.assertEqual(calls, [(me, os.getgid(), [])])
        self.assertFalse(os.path.exists(self.p("base", "id")))
        self.assertTrue(os.path.exists(self.p("outside", "keep")))

    def test_owner_refusing_falls_back_to_root(self):
        self.tree()
        b = self.base_fd()
        me = os.geteuid()
        try:
            with mock.patch.object(os, "geteuid", lambda: me + 1), mock.patch.object(os, "chown", lambda *a, **k: None):
                vmroot.remove_rt("base/id", uid=me, base_fd=b, as_owner=lambda creds, fn: False)
        finally:
            os.close(b)
        self.assertFalse(os.path.exists(self.p("base", "id")))
        self.assertTrue(os.path.exists(self.p("outside", "keep")))

    def test_other_filesystem_left_alone(self):
        os.makedirs(self.p("x", "y"))
        fd = os.open(self.d, os.O_PATH | os.O_DIRECTORY)
        try:
            with self.assertRaises(OSError) as cm:
                vmroot.rmtree_at(fd, "x", os.fstat(fd).st_dev + 1)
            self.assertEqual(cm.exception.errno, errno.EXDEV)
        finally:
            os.close(fd)
        self.assertTrue(os.path.isdir(self.p("x", "y")))

    def test_cleanup_paths(self):
        for base, rt in (("/run/sandbox-vm/x", "/run/sandbox-vm/y/main"), ("/run/sandbox-vm/x", "/run/sandbox-vm/x/a/b")):
            with self.assertRaises(vmroot.Refused):
                vmroot.cleanup(base, "main", rt)


class Sockets(Tmp):
    def test_open_socket(self):
        s = socket.socket(socket.AF_UNIX)
        s.bind(self.p("gpu.sock"))
        os.symlink(self.p("gpu.sock"), self.p("link.sock"))
        open(self.p("file.sock"), "w").close()
        d = os.open(self.d, os.O_PATH | os.O_DIRECTORY)
        try:
            fd = vmroot.open_socket(d, "gpu.sock", os.getuid())
            self.assertTrue(stat.S_ISSOCK(os.fstat(fd).st_mode))
            os.close(fd)
            with self.assertRaises(vmroot.Refused):
                vmroot.open_socket(d, "gpu.sock", os.getuid() + 1)
            with self.assertRaises(vmroot.Refused):
                vmroot.open_socket(d, "file.sock", os.getuid())
            # O_PATH|O_NOFOLLOW opens the link itself, which isn't a socket.
            with self.assertRaises(vmroot.Refused):
                vmroot.open_socket(d, "link.sock", os.getuid())
            vmroot.wait_sockets(d, ["gpu.sock"], timeout=0.2)
            with self.assertRaises(vmroot.Refused):
                vmroot.wait_sockets(d, ["file.sock"], timeout=0.2)
        finally:
            os.close(d)
            s.close()

    def test_mountpoints(self):
        d = os.open(self.d, os.O_PATH | os.O_DIRECTORY)
        try:
            os.close(vmroot.mountpoint(d, "e0", True))
            os.close(vmroot.mountpoint(d, "b1", False))
            with self.assertRaises(FileExistsError):
                vmroot.mountpoint(d, "b1", False)
            os.symlink("/etc/passwd", self.p("b2"))
            with self.assertRaises(FileExistsError):
                vmroot.mountpoint(d, "b2", False)
        finally:
            os.close(d)
        self.assertTrue(os.path.isdir(self.p("e0")))
        self.assertTrue(stat.S_ISREG(os.lstat(self.p("b1")).st_mode))


class Parsing(Tmp):
    def test_unit_of(self):
        self.assertEqual(vmroot.unit_of("0::/system.slice/sandbox-vm-x.service\n"), "sandbox-vm-x.service")
        t = "0::/system.slice/system-sandbox\\x2dvm.slice/sandbox-vm-x-gpu@home-u-p.service\n"
        self.assertEqual(vmroot.unit_of(t), "sandbox-vm-x-gpu@home-u-p.service")
        self.assertIsNone(vmroot.unit_of("1:name=systemd:/x\n"))

    def test_video_devices(self):
        def dev(name, cls, bus, num, product=None):
            os.makedirs(self.p(name, f"{name}:1.0"))
            for f, v in (("busnum", bus), ("devnum", num)):
                with open(self.p(name, f), "w") as fh:
                    fh.write(f"{v}\n")
            with open(self.p(name, f"{name}:1.0", "bInterfaceClass"), "w") as fh:
                fh.write(cls + "\n")
            if product:
                with open(self.p(name, "product"), "w") as fh:
                    fh.write(product + "\n")

        dev("1-2", "0e", 1, 5, "Webcam")
        dev("1-3", "03", 1, 6)  # a keyboard
        dev("3-1.4", "0e", 3, 9)
        os.makedirs(self.p("usb1"))
        os.makedirs(self.p("1-2:1.0x"))
        self.assertEqual(vmroot.video_devices(self.d), [("1-2", 1, 5, "Webcam"), ("3-1.4", 3, 9, "3-1.4")])

    def test_drop_caps(self):
        # Unprivileged: nothing to drop, and it must not fail.
        vmroot.drop_caps(vmroot.CAP_SYS_PTRACE)


class StageFlow(Tmp):
    """stage() with the privileged calls mocked: what gets opened, cloned with
    which attributes, and mounted onto what kind of mount point."""

    def setUp(self):
        super().setUp()
        os.makedirs(self.p("run", "sandbox-vm", "vm"))
        os.makedirs(self.p("home", "u", ".config", "x"))
        open(self.p("home", "u", ".gitconfig"), "w").close()
        os.makedirs(self.p("home", "u", "proj"))
        os.makedirs(self.p("home", "u", "real"))
        os.symlink(self.p("home", "u", "real"), self.p("home", "u", "planted"))
        self.moves = []
        self.attrs = []
        root = self.d
        patches = [
            mock.patch.object(vmroot, "enter_host_mount_ns", lambda: None),
            mock.patch.object(vmroot, "drop_to", lambda *a: None),
            mock.patch.object(
                vmroot, "open_trusted", lambda path, *a, **k: os.open(root + path, os.O_PATH | os.O_DIRECTORY)
            ),
            mock.patch.object(vmroot, "private_tmpfs", lambda fd: None),
            mock.patch.object(vmroot, "open_tree", lambda fd, recursive: os.dup(fd)),
            mock.patch.object(vmroot, "mount_setattr", lambda fd, attr_set=0, **k: self.attrs.append(attr_set)),
            mock.patch.object(
                vmroot, "move_mount", lambda tree, mp: self.moves.append((os.readlink(f"/proc/self/fd/{tree}"), os.fstat(mp)))
            ),
        ]
        for pt in patches:
            pt.start()
            self.addCleanup(pt.stop)
        self.user = {"name": "u", "uid": os.getuid(), "gid": os.getgid(), "home": self.p("home", "u")}

    def cfg(self, items, cwd=False):
        return {"user": self.user, "items": items, "cwd": cwd}

    def test_items(self):
        h = self.p("home", "u")
        items = [
            {"name": "e0", "path": f"{h}/.config/x", "kind": "dir", "under": h},
            {"name": "b0", "path": f"{h}/.gitconfig", "kind": "any", "ro": True, "under": h},
            {"name": "b1", "path": f"{h}/missing", "kind": "any", "under": h},
            {"name": "b2", "path": f"{h}/planted", "kind": "any", "under": h},
            {"name": "b3", "path": f"{h}/.gitconfig", "kind": "dir", "under": h},
        ]
        n = vmroot.stage(self.cfg(items, cwd=True), "/run/sandbox-vm/vm", "k", f"{h}/proj")
        self.assertEqual(n, 3)
        stage = self.p("run", "sandbox-vm", "vm", "stage", "k")
        self.assertEqual(sorted(os.listdir(stage)), ["b0", "cwd", "e0"])
        self.assertTrue(os.path.isdir(os.path.join(stage, "e0")))
        self.assertTrue(stat.S_ISREG(os.lstat(os.path.join(stage, "b0")).st_mode))
        self.assertEqual([m[0] for m in self.moves], [f"{h}/proj", f"{h}/.config/x", f"{h}/.gitconfig"])
        ro = vmroot.MOUNT_ATTR_RDONLY
        base = vmroot.MOUNT_ATTR_NOSUID | vmroot.MOUNT_ATTR_NODEV
        self.assertEqual(self.attrs, [base, base, base | ro])

    def test_project_must_open(self):
        h = self.p("home", "u")
        for project in (f"{h}/nope", f"{h}/planted", f"{h}/.gitconfig"):
            with self.assertRaises((vmroot.Refused, OSError), msg=project):
                vmroot.stage(self.cfg([], cwd=True), "/run/sandbox-vm/vm", "k", project)
            # Nothing was mounted for it.
            self.assertEqual(self.moves, [])
            os.rmdir(self.p("run", "sandbox-vm", "vm", "stage", "k"))

    def test_socket_must_be_the_users(self):
        s = socket.socket(socket.AF_UNIX)
        s.bind(self.p("home", "u", "b.sock"))
        self.addCleanup(s.close)
        item = {"name": "relay-broker", "path": self.p("home", "u", "b.sock"), "kind": "socket", "owned": True}
        self.assertEqual(vmroot.stage(self.cfg([item]), "/run/sandbox-vm/vm", "k1"), 1)
        self.user["uid"] += 1  # someone else's socket now
        with mock.patch.object(vmroot, "user_creds", lambda u: (os.getuid(), os.getgid(), [])):
            self.assertEqual(vmroot.stage(self.cfg([item]), "/run/sandbox-vm/vm", "k2"), 0)


class GpuOpenFlow(Tmp):
    def test_handover(self):
        os.makedirs(self.p("rt", "gpu"))
        socks = []
        for n in ("gpu.sock", "inject.sock"):
            s = socket.socket(socket.AF_UNIX)
            s.bind(self.p("rt", "gpu", n))
            socks.append(s)
            self.addCleanup(s.close)
        grants, chowns = [], []
        me = os.getuid()
        pw = mock.Mock(pw_uid=me, pw_gid=os.getgid())
        root = self.d
        with mock.patch.object(vmroot.pwd, "getpwnam", lambda n: pw), mock.patch.object(
            vmroot, "open_trusted", lambda path, *a, **k: os.open(root + path, os.O_PATH | os.O_DIRECTORY)
        ), mock.patch.object(vmroot, "drop_to", lambda *a: None), mock.patch.object(
            os, "chown", lambda *a, **k: chowns.append((a, k))
        ), mock.patch.object(
            vmroot, "grant_socket", lambda setfacl, fd, user: grants.append((os.readlink(f"/proc/self/fd/{fd}"), user))
        ):
            vmroot.gpu_open("/rt", "sbx-gpu-x", "app-x", "sbx-cap-x", "setfacl")
        self.assertEqual(chowns, [(("gpu", 0, 0), {"dir_fd": mock.ANY, "follow_symlinks": False})])
        self.assertEqual(stat.S_IMODE(os.stat(self.p("rt", "gpu")).st_mode), 0o711)
        self.assertEqual(grants, [(self.p("rt", "gpu", "gpu.sock"), "app-x"), (self.p("rt", "gpu", "inject.sock"), "sbx-cap-x")])


if __name__ == "__main__":
    unittest.main()
