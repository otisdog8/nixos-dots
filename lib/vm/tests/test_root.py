"""Unprivileged tests for lib/vm/root.py (sbx-vm-root): the path checks root
relies on (root-only chains, opening exactly the path asked for, never through
a symlink, the store-link exception, per-project path rules, stage items,
stash entries), the fd-passing child, the idmap's maps and its user namespace
(made for real where unprivileged user namespaces are allowed), which
capabilities go before the host's mount namespace is entered, the removal of a
launch's runtime dir (never following a link or leaving the filesystem, other
owners' folders emptied as their owner), socket checks, the cgroup and sysfs
parsing. The mounts, setns, ownership changes and prctl need root and real
VMs.

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
        # "rt" is the launch dir's; a stash entry is a folder or a file.
        for bad in (dict(ok, name="rt"), dict(ok, stash=True, kind="any"), dict(ok, stash=True, kind="socket")):
            with self.assertRaises(vmroot.Refused, msg=repr(bad)):
                vmroot.check_item(bad, self.user)

    def test_cwd_item(self):
        cfg = {"user": self.user, "items": [], "cwd": True}
        items = vmroot.stage_items(cfg, "/home/u/proj")
        self.assertEqual(
            items[0], {"name": "cwd", "path": "/home/u/proj", "kind": "dir", "required": True, "idmap": True}
        )
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
                    vmroot.stage(cfg, "/run/sandbox-vm/x", key, "/run/sandbox-vm/x/main", project)
            bad = {"user": self.user, "items": [{"name": "e0", "path": "/root/x", "kind": "dir", "under": "/home/u"}]}
            with self.assertRaises(vmroot.Refused):
                vmroot.stage(bad, "/run/sandbox-vm/x", "main", "/run/sandbox-vm/x/main")
            ok = {"user": self.user, "items": []}
            for rt in ("/run/sandbox-vm/y/main", "/run/sandbox-vm/x/a/b", "/run/sandbox-vm/x/../y", "/run/sandbox-vm/x"):
                with self.assertRaises(vmroot.Refused, msg=rt):
                    vmroot.stage(ok, "/run/sandbox-vm/x", "main", rt)


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

    def test_cleanup_key(self):
        """The key names one stage under base/stage, as for `stage`: never the
        stage itself or what's above it (which unstage would unmount)."""
        with mock.patch.object(vmroot, "unstage", lambda *a: self.fail("unstaged")):
            for key in ("", ".", "..", "a/b", "../x", "a\0b", "k" * 256):
                with self.assertRaises(vmroot.Refused, msg=repr(key)):
                    vmroot.cleanup("/run/sandbox-vm/x", key, "/run/sandbox-vm/x/main")


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



class FakeCapLibc:
    """libc's prctl/capget/capset, recording what was asked: a process with
    every capability up to CAP_LAST in its bounding, effective and permitted
    sets."""

    LAST = 40

    def __init__(self, calls):
        self.calls = calls
        self.bounding = set(range(self.LAST + 1))

    def prctl(self, option, arg, *rest):
        option, arg = option.value, arg.value
        if option == vmroot.PR_CAPBSET_READ:
            return -1 if arg > self.LAST else int(arg in self.bounding)
        if option == vmroot.PR_CAPBSET_DROP:
            if vmroot.CAP_SETPCAP not in self.bounding:
                return -1  # EPERM: CAP_SETPCAP went first
            self.bounding.discard(arg)
            self.calls.append(("drop", arg))
            return 0
        self.calls.append(("prctl", option, arg))
        return 0

    def capget(self, hdr, data):
        for d in data:
            d.effective = d.permitted = d.inheritable = 0xFFFFFFFF
        return 0

    def capset(self, hdr, data):
        caps = lambda field: {c for c in range(64) if getattr(data[c // 32], field) >> (c % 32) & 1}
        self.calls.append(("capset", caps("effective"), caps("permitted"), caps("inheritable")))
        return 0


class Caps(unittest.TestCase):
    def test_restrict_caps(self):
        calls = []
        fake = FakeCapLibc(calls)
        with mock.patch.object(vmroot, "libc", fake):
            vmroot.restrict_caps(vmroot.HOST_NS_CAPS)
        dropped = [c[1] for c in calls if c[0] == "drop"]
        self.assertEqual(set(dropped), set(range(FakeCapLibc.LAST + 1)) - vmroot.HOST_NS_CAPS)
        # CAP_SETPCAP (which the drops need) last of them, then the ambient set
        # cleared, then the rest cut down.
        self.assertEqual(dropped[-1], vmroot.CAP_SETPCAP)
        self.assertEqual(fake.bounding, set(vmroot.HOST_NS_CAPS))
        self.assertEqual(calls[-2], ("prctl", vmroot.PR_CAP_AMBIENT, vmroot.PR_CAP_AMBIENT_CLEAR_ALL))
        self.assertEqual(calls[-1], ("capset", set(vmroot.HOST_NS_CAPS), set(vmroot.HOST_NS_CAPS), set()))
        for c in (vmroot.CAP_SYS_PTRACE, 0, 1, 3):  # PTRACE, CHOWN, DAC_OVERRIDE, FOWNER
            self.assertNotIn(c, vmroot.HOST_NS_CAPS)

    def test_a_failed_drop_fails(self):
        fake = FakeCapLibc([])
        fake.bounding.discard(vmroot.CAP_SETPCAP)  # can't drop anything
        with mock.patch.object(vmroot, "libc", fake):
            with self.assertRaises(OSError):
                vmroot.restrict_caps(vmroot.HOST_NS_CAPS)

    def test_dropped_before_setns(self):
        """The namespace is opened (CAP_SYS_PTRACE) first, every capability
        but HOST_NS_CAPS goes, and only then is it entered."""
        calls = []
        fake = FakeCapLibc(calls)
        real_open = os.open

        def fake_open(path, flags, *a, **k):
            if path == "/proc/1/ns/mnt":
                calls.append(("open", path))
                return real_open("/", os.O_RDONLY)
            return real_open(path, flags, *a, **k)

        with mock.patch.object(vmroot, "libc", fake), mock.patch.object(vmroot.os, "open", fake_open), mock.patch.object(
            vmroot.os, "setns", lambda fd, nstype: calls.append(("setns", nstype)), create=True
        ):
            vmroot.enter_host_mount_ns()
        kinds = [c[0] for c in calls]
        self.assertEqual(kinds[0], "open")
        self.assertEqual(calls[-1], ("setns", vmroot.CLONE_NEWNS))
        self.assertEqual(calls[-2][0], "capset")
        self.assertEqual(kinds.count("setns"), 1)
        self.assertLess(max(i for i, k in enumerate(kinds) if k == "drop"), kinds.index("setns"))


class Idmap(unittest.TestCase):
    def test_lines(self):
        self.assertEqual(vmroot.idmap_lines([(1000, 987)]), "1000 987 1\n")
        self.assertEqual(vmroot.idmap_lines([(1000, 987), (0, 990)]), "1000 987 1\n0 990 1\n")
        for bad in ([], [(1000, 1000), (1000, 2)], [(1, 5), (2, 5)], [(-1, 5)], [(1, 2**32 - 1)], [("1", 5)], [(True, 5)], [(1.0, 5)]):
            with self.assertRaises(vmroot.Refused, msg=repr(bad)):
                vmroot.idmap_lines(bad)

    def test_stage_idmap(self):
        user = {"name": "u", "uid": 1000, "gid": 100}
        self.assertIsNone(vmroot.stage_idmap({"user": user}))
        self.assertIsNone(vmroot.stage_idmap({"user": user, "idmap": None}))
        with mock.patch.object(vmroot.pwd, "getpwnam", lambda n: mock.Mock(pw_uid=987, pw_gid=985)):
            self.assertEqual(vmroot.stage_idmap({"user": user, "idmap": "sbx-vm-x"}), ([(1000, 987)], [(100, 985)]))
        # Never root, never the user itself.
        for uid, gid in ((0, 985), (987, 0), (1000, 985), (987, 100)):
            with mock.patch.object(vmroot.pwd, "getpwnam", lambda n: mock.Mock(pw_uid=uid, pw_gid=gid)):
                with self.assertRaises(vmroot.Refused):
                    vmroot.stage_idmap({"user": user, "idmap": "sbx-vm-x"})

    def test_userns(self):
        """For real, with the one mapping an unprivileged writer may set (its
        own ids onto themselves); root writes others the same way."""
        me, mg = os.getuid(), os.getgid()
        try:
            fd = vmroot.idmap_userns([(me, me)], [(mg, mg)])
        except (vmroot.Refused, PermissionError) as e:
            self.skipTest(f"no unprivileged user namespaces here: {e}")
        try:
            name = os.readlink(f"/proc/self/fd/{fd}")
            self.assertTrue(name.startswith("user:["), name)
            self.assertNotEqual(name, os.readlink("/proc/self/ns/user"))
        finally:
            os.close(fd)

    def test_userns_child_failing(self):
        with mock.patch.object(vmroot.os, "unshare", side_effect=PermissionError("no")):
            with self.assertRaises(vmroot.Refused):
                vmroot.idmap_userns([(1, 2)], [(1, 2)])


class StageFlow(Tmp):
    """stage() with the privileged calls mocked: what gets opened, cloned with
    which attributes (idmapped or not), and mounted onto what kind of mount
    point."""

    def setUp(self):
        super().setUp()
        os.makedirs(self.p("run", "sandbox-vm", "vm", "main"))
        os.makedirs(self.p("home", "u", ".config", "x"))
        open(self.p("home", "u", ".gitconfig"), "w").close()
        os.makedirs(self.p("home", "u", "proj"))
        os.makedirs(self.p("home", "u", "real"))
        os.symlink(self.p("home", "u", "real"), self.p("home", "u", "planted"))
        os.makedirs(self.p("persist", "sandbox", "app", ".data"))
        open(self.p("persist", "sandbox", "app", "conf"), "w").close()
        os.symlink(".data", self.p("persist", "sandbox", "app", "linked"))
        self.moves = []
        self.attrs = []
        self.props = []
        self.userns = []
        self.private_roots = []
        root = self.d
        patches = [
            mock.patch.object(vmroot, "enter_host_mount_ns", lambda: None),
            mock.patch.object(vmroot, "drop_to", lambda *a: None),
            mock.patch.object(
                vmroot, "open_trusted", lambda path, *a, **k: os.open(root + path, os.O_PATH | os.O_DIRECTORY)
            ),
            mock.patch.object(vmroot, "private_tmpfs", lambda fd: None),
            mock.patch.object(vmroot, "private_mount_root", self.private_root),
            mock.patch.object(vmroot, "open_tree", lambda fd, recursive: os.dup(fd)),
            mock.patch.object(vmroot, "mount_setattr", self.setattr),
            mock.patch.object(
                vmroot, "move_mount", lambda tree, mp: self.moves.append((os.readlink(f"/proc/self/fd/{tree}"), os.fstat(mp)))
            ),
            mock.patch.object(vmroot, "idmap_userns", self.make_userns),
            mock.patch.object(vmroot.pwd, "getpwnam", lambda n: mock.Mock(pw_uid=os.getuid() + 1, pw_gid=os.getgid() + 1)),
        ]
        for pt in patches:
            pt.start()
            self.addCleanup(pt.stop)
        self.user = {"name": "u", "uid": os.getuid(), "gid": os.getgid(), "home": self.p("home", "u")}
        self.fail_idmap = set()

    def setattr(self, fd, attr_set=0, propagation=0, userns_fd=0, **k):
        path = os.readlink(f"/proc/self/fd/{fd}")
        if attr_set & vmroot.MOUNT_ATTR_IDMAP and path in self.fail_idmap:
            raise OSError(errno.EINVAL, "Invalid argument")
        self.attrs.append((path, attr_set, userns_fd))
        self.props.append((path, propagation))

    def private_root(self, parent_fd, name):
        self.private_roots.append(os.path.join(os.readlink(f"/proc/self/fd/{parent_fd}"), name))

    def make_userns(self, uids, gids):
        self.userns.append((uids, gids))
        return os.open("/", os.O_RDONLY)

    def cfg(self, items, cwd=False, idmap=None):
        return {"user": self.user, "items": items, "cwd": cwd, "stashOwner": "u", "idmap": idmap}

    def stage(self, cfg, key="k", project=None):
        return vmroot.stage(cfg, "/run/sandbox-vm/vm", key, "/run/sandbox-vm/vm/main", project)

    def test_items(self):
        h = self.p("home", "u")
        items = [
            {"name": "e0", "path": f"{h}/.config/x", "kind": "dir", "under": h},
            {"name": "b0", "path": f"{h}/.gitconfig", "kind": "any", "ro": True, "under": h},
            {"name": "b1", "path": f"{h}/missing", "kind": "any", "under": h},
            {"name": "b2", "path": f"{h}/planted", "kind": "any", "under": h},
            {"name": "b3", "path": f"{h}/.gitconfig", "kind": "dir", "under": h},
        ]
        n = self.stage(self.cfg(items, cwd=True), project=f"{h}/proj")
        self.assertEqual(n, 3)
        stage = self.p("run", "sandbox-vm", "vm", "stage", "k")
        self.assertEqual(sorted(os.listdir(stage)), ["b0", "cwd", "e0", "rt"])
        self.assertTrue(os.path.isdir(os.path.join(stage, "e0")))
        self.assertTrue(stat.S_ISREG(os.lstat(os.path.join(stage, "b0")).st_mode))
        rt = self.p("run", "sandbox-vm", "vm", "main")
        self.assertEqual([m[0] for m in self.moves], [f"{h}/proj", f"{h}/.config/x", f"{h}/.gitconfig", rt])
        ro = vmroot.MOUNT_ATTR_RDONLY
        base = vmroot.MOUNT_ATTR_NOSUID | vmroot.MOUNT_ATTR_NODEV
        self.assertEqual(
            [a[1] for a in self.attrs], [base, base, base | ro, base | vmroot.MOUNT_ATTR_NOEXEC]
        )
        # Every clone private (no peer of its source left), and the stage's
        # parent a private mount before anything is mounted under it.
        self.assertEqual([p[1] for p in self.props], [vmroot.MS_PRIVATE] * 4)
        self.assertEqual(self.private_roots, [self.p("run", "sandbox-vm", "vm", "stage")])
        # Not a VM of its own uid: nothing idmapped.
        self.assertEqual(self.userns, [])

    def test_stash(self):
        """Stash entries are opened by root, must be the owner's and no link,
        and must be there."""
        app = self.p("persist", "sandbox", "app")
        items = [
            {"name": "e0", "path": "/persist/sandbox/app/.data", "kind": "dir", "stash": True, "required": True},
            {"name": "e1", "path": "/persist/sandbox/app/conf", "kind": "file", "stash": True, "required": True},
        ]
        # open_trusted is mocked onto the test's root; the entry is opened in it.
        with mock.patch.object(vmroot, "open_trusted", lambda path, *a, **k: os.open(self.d + path, os.O_PATH | os.O_DIRECTORY)):
            with mock.patch.object(vmroot.pwd, "getpwnam", lambda n: mock.Mock(pw_uid=os.getuid())):
                self.assertEqual(self.stage(self.cfg(items)), 2)
                self.assertEqual([m[0] for m in self.moves[:2]], [f"{app}/.data", f"{app}/conf"])
                for bad in (
                    {"name": "e0", "path": "/persist/sandbox/app/linked", "kind": "dir", "stash": True, "required": True},
                    {"name": "e0", "path": "/persist/sandbox/app/conf", "kind": "dir", "stash": True, "required": True},
                    {"name": "e0", "path": "/persist/sandbox/app/gone", "kind": "dir", "stash": True, "required": True},
                ):
                    with self.assertRaises((vmroot.Refused, OSError), msg=bad["path"]):
                        self.stage(self.cfg([bad]), key="k2")
                    os.rmdir(self.p("run", "sandbox-vm", "vm", "stage", "k2"))
            # Someone else's entry.
            with mock.patch.object(vmroot.pwd, "getpwnam", lambda n: mock.Mock(pw_uid=os.getuid() + 1)):
                with self.assertRaises(vmroot.Refused):
                    self.stage(self.cfg(items[:1]), key="k3")

    def test_idmapped(self):
        """A VM of its own uid: one user namespace mapping the user's uid and
        group onto the VM's, every data item idmapped through it (sockets and
        the document view not), and what can't be idmapped isn't shared at all
        (or fails the VM, if it must be)."""
        h = self.p("home", "u")
        s = socket.socket(socket.AF_UNIX)
        s.bind(self.p("home", "u", "b.sock"))
        self.addCleanup(s.close)
        items = [
            {"name": "e0", "path": f"{h}/.config/x", "kind": "dir", "under": h, "idmap": True},
            {"name": "b0", "path": f"{h}/.gitconfig", "kind": "any", "ro": True, "under": h, "idmap": True},
            {"name": "b1", "path": f"{h}/real", "kind": "any", "under": h, "idmap": True},
            {"name": "relay-broker", "path": f"{h}/b.sock", "kind": "socket", "owned": True},
        ]
        self.fail_idmap = {f"{h}/real"}
        n = self.stage(self.cfg(items, cwd=True, idmap="sbx-vm-vm"), project=f"{h}/proj")
        self.assertEqual(n, 4)
        me, mg = os.getuid(), os.getgid()
        self.assertEqual(self.userns, [([(me, me + 1)], [(mg, mg + 1)])])
        idmapped = [a[0] for a in self.attrs if a[1] == vmroot.MOUNT_ATTR_IDMAP]
        self.assertEqual(idmapped, [f"{h}/proj", f"{h}/.config/x", f"{h}/.gitconfig"])
        self.assertTrue(all(a[2] > 0 for a in self.attrs if a[1] == vmroot.MOUNT_ATTR_IDMAP))
        moved = [m[0] for m in self.moves]
        self.assertNotIn(f"{h}/real", moved)
        self.assertIn(f"{h}/b.sock", moved)
        # The project must be shared: one that can't be idmapped fails the VM.
        self.fail_idmap = {f"{h}/proj"}
        with self.assertRaises(vmroot.Refused):
            self.stage(self.cfg([], cwd=True, idmap="sbx-vm-vm"), key="k2", project=f"{h}/proj")

    def test_project_must_open(self):
        h = self.p("home", "u")
        for project in (f"{h}/nope", f"{h}/planted", f"{h}/.gitconfig"):
            with self.assertRaises((vmroot.Refused, OSError), msg=project):
                self.stage(self.cfg([], cwd=True), project=project)
            # Nothing was mounted for it.
            self.assertEqual(self.moves, [])
            os.rmdir(self.p("run", "sandbox-vm", "vm", "stage", "k"))

    def test_socket_must_be_the_users(self):
        s = socket.socket(socket.AF_UNIX)
        s.bind(self.p("home", "u", "b.sock"))
        self.addCleanup(s.close)
        item = {"name": "relay-broker", "path": self.p("home", "u", "b.sock"), "kind": "socket", "owned": True}
        self.assertEqual(self.stage(self.cfg([item]), key="k1"), 1)
        self.user["uid"] += 1  # someone else's socket now
        with mock.patch.object(vmroot, "user_creds", lambda u: (os.getuid(), os.getgid(), [])):
            self.assertEqual(self.stage(self.cfg([item]), key="k2"), 0)


class PrivateMountRoot(Tmp):
    """The stage's parent becomes a private bind onto itself, once."""

    def setUp(self):
        super().setUp()
        os.makedirs(self.p("base", "stage"))
        self.calls = []
        for name, fn in (
            ("open_tree", lambda fd, recursive: self.calls.append(("clone", recursive)) or os.dup(fd)),
            ("mount_setattr", lambda fd, **k: self.calls.append(("setattr", k))),
            ("move_mount", lambda tree, dst: self.calls.append(("move", os.readlink(f"/proc/self/fd/{dst}")))),
        ):
            pt = mock.patch.object(vmroot, name, fn)
            pt.start()
            self.addCleanup(pt.stop)

    def run_it(self):
        b = os.open(self.p("base"), os.O_PATH | os.O_DIRECTORY)
        try:
            vmroot.private_mount_root(b, "stage")
        finally:
            os.close(b)

    def test_binds_private_onto_itself(self):
        self.run_it()
        self.assertEqual(
            self.calls,
            [
                ("clone", False),
                ("setattr", {"propagation": vmroot.MS_PRIVATE, "recursive": False}),
                ("move", self.p("base", "stage")),
            ],
        )

    def test_already_a_mount(self):
        ids = iter([2, 1])
        with mock.patch.object(vmroot, "mount_id", lambda fd: next(ids)):
            self.run_it()
        self.assertEqual(self.calls, [])

    def test_never_through_a_link(self):
        os.rmdir(self.p("base", "stage"))
        os.makedirs(self.p("elsewhere"))
        os.symlink(self.p("elsewhere"), self.p("base", "stage"))
        with self.assertRaises(OSError):
            self.run_it()
        self.assertEqual(self.calls, [])


class Coresched(unittest.TestCase):
    """The cookie only moves while both processes are still the ones pinned."""

    def setUp(self):
        self.calls = []
        self.cookies = {}
        self.living = {"b": True, "v": True}
        for name, fn in (
            ("main_pid", lambda systemctl, unit: {"be.service": 10, "vmm.service": 20}[unit]),
            ("pinned", lambda pid, unit: {10: "b", 20: "v"}[pid]),
            ("alive", lambda fd: self.living[fd]),
            ("cookie", lambda pid: self.cookies.get(pid, 0)),
            ("sched_core", self.sched),
        ):
            pt = mock.patch.object(vmroot, name, fn)
            pt.start()
            self.addCleanup(pt.stop)
        pt = mock.patch.object(vmroot.os, "close", lambda fd: None)
        pt.start()
        self.addCleanup(pt.stop)
        pt = mock.patch.object(vmroot.time, "sleep", lambda s: None)
        pt.start()
        self.addCleanup(pt.stop)

    def sched(self, cmd, pid, scope, addr=None):
        self.calls.append((cmd, pid))
        if cmd == vmroot.PR_SCHED_CORE_SHARE_FROM:
            self.cookies[0] = self.cookies.get(pid, 0)
        elif cmd == vmroot.PR_SCHED_CORE_SHARE_TO:
            self.cookies[pid] = self.cookies.get(0, 0)

    def run_it(self):
        vmroot.coresched("be.service", "vmm.service", "systemctl")

    def test_shares(self):
        self.cookies[20] = 7
        self.run_it()
        self.assertEqual(self.calls, [(vmroot.PR_SCHED_CORE_SHARE_FROM, 20), (vmroot.PR_SCHED_CORE_SHARE_TO, 10)])
        self.assertEqual(self.cookies[10], 7)

    def test_backend_gone_before_anything(self):
        self.cookies[20] = 7
        self.living["b"] = False
        self.run_it()
        self.assertEqual(self.calls, [])

    def test_vmm_gone_after_share_from(self):
        """The VMM's pid may have been someone else's by then: nothing is given
        to the backend."""
        self.cookies[20] = 7

        def sched(cmd, pid, scope, addr=None):
            self.calls.append((cmd, pid))
            self.living["v"] = False

        with mock.patch.object(vmroot, "sched_core", sched):
            self.run_it()
        self.assertEqual(self.calls, [(vmroot.PR_SCHED_CORE_SHARE_FROM, 20)])


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
