"""Unprivileged tests for lib/broker/attach.py: the record parsing and the
symlink-safe mount-point creation (the mounts themselves need root and a live
sandbox). Run with TMPDIR on a tmpfs: python3 -m unittest lib/broker/tests/test_attach.py"""

import errno
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("attach", os.path.join(HERE, "..", "attach.py"))
attach = importlib.util.module_from_spec(spec)
spec.loader.exec_module(attach)


class Records(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.rt = os.path.realpath(self.tmp.name)
        if attach.statfs_type(os.open(self.rt, os.O_PATH)) != attach.TMPFS_MAGIC:
            self.skipTest("TMPDIR must be on a tmpfs")
        os.mkdir(os.path.join(self.rt, ".flatpak"))

    def tearDown(self):
        self.tmp.cleanup()

    def add(self, name, pid, info):
        d = os.path.join(self.rt, ".flatpak", name)
        os.mkdir(d)
        with open(os.path.join(d, "bwrapinfo.json"), "w") as f:
            json.dump({"child-pid": pid}, f)
        with open(os.path.join(d, "info"), "w") as f:
            f.write(info)
        return d

    def test_reads_nixpak_records(self):
        self.add("nixpak-app-1", 1234, "[Application]\nname=com.nixpak.Zoom\n")
        self.assertEqual(attach.records(self.rt), [(1234, "com.nixpak.Zoom")])

    def test_skips_others_and_garbage(self):
        self.add("sandbox-vm-x", 99, "[Application]\nname=a\n")  # not nixpak's
        self.add("nixpak-app-2", 1, "[Application]\nname=a\n")  # pid 1
        self.add("nixpak-app-3", 55, "[Context]\nname=a\n")  # no app name
        d = self.add("nixpak-app-4", 56, "[Application]\nname=b\n")
        os.remove(os.path.join(d, "bwrapinfo.json"))
        os.mkfifo(os.path.join(d, "bwrapinfo.json"))  # must not hang
        d = self.add("nixpak-app-5", 57, "[Application]\nname=c\n")
        os.remove(os.path.join(d, "info"))
        os.symlink("/etc/passwd", os.path.join(d, "info"))  # never followed
        self.assertEqual(attach.records(self.rt), [])

    def test_no_dir(self):
        self.assertEqual(attach.records(os.path.join(self.rt, "missing")), [])

    def test_never_through_a_symlink(self):
        """The user (or the app) owns everything below the runtime dir: a
        record folder, or .flatpak itself, swapped for a link to records
        elsewhere is not read."""
        with tempfile.TemporaryDirectory() as other:
            os.mkdir(os.path.join(other, ".flatpak"))
            d = os.path.join(other, ".flatpak", "nixpak-app-9")
            os.mkdir(d)
            with open(os.path.join(d, "bwrapinfo.json"), "w") as f:
                json.dump({"child-pid": 4321}, f)
            with open(os.path.join(d, "info"), "w") as f:
                f.write("[Application]\nname=x\n")
            os.symlink(d, os.path.join(self.rt, ".flatpak", "nixpak-app-9"))
            self.assertEqual(attach.records(self.rt), [])
            os.remove(os.path.join(self.rt, ".flatpak", "nixpak-app-9"))
            os.rmdir(os.path.join(self.rt, ".flatpak"))
            os.symlink(os.path.join(other, ".flatpak"), os.path.join(self.rt, ".flatpak"))
            self.assertEqual(attach.records(self.rt), [])
            # Nor a runtime dir that is itself a link.
            self.assertEqual(attach.records(os.path.join(self.rt, ".flatpak", "..")), [])
            link = os.path.join(self.rt, "rt")
            os.symlink(other, link)
            self.assertEqual(attach.records(link), [])


class Mountpoint(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        if attach.statfs_type(os.open(self.root, os.O_PATH)) != attach.TMPFS_MAGIC:
            self.skipTest("TMPDIR must be on a tmpfs")
        self.uid = os.getuid()

    def tearDown(self):
        self.tmp.cleanup()

    def mp(self, path, is_dir):
        fd = attach.make_mountpoint(path, is_dir, self.uid, root=self.root)
        try:
            return os.fstat(fd)
        finally:
            os.close(fd)

    def test_creates_dirs(self):
        st = self.mp("/home/u/Documents/proj", True)
        self.assertTrue(stat.S_ISDIR(st.st_mode))
        self.assertTrue(os.path.isdir(os.path.join(self.root, "home/u/Documents/proj")))

    def test_creates_device_mountpoint_file(self):
        st = self.mp("/dev/video0", False)
        self.assertTrue(stat.S_ISREG(st.st_mode))

    def test_existing_ok(self):
        os.makedirs(os.path.join(self.root, "a/b"))
        self.assertTrue(stat.S_ISDIR(self.mp("/a/b", True).st_mode))

    def test_refuses_symlink_in_path(self):
        os.makedirs(os.path.join(self.root, "real"))
        os.symlink("/etc", os.path.join(self.root, "link"))
        with self.assertRaises(attach.Refused):
            self.mp("/link/x", True)
        self.assertFalse(os.path.exists(os.path.join(self.root, "real", "x")))

    def test_refuses_symlink_as_target(self):
        os.symlink("/etc", os.path.join(self.root, "t"))
        with self.assertRaises(attach.Refused):
            self.mp("/t", True)
        os.symlink("/etc/passwd", os.path.join(self.root, "f"))
        with self.assertRaises((attach.Refused, OSError)):
            self.mp("/f", False)

    def test_refuses_dotdot(self):
        with self.assertRaises(attach.Refused):
            self.mp("/a/../b", True)

    def test_pidfd_gid(self):
        fd = os.pidfd_open(os.getpid())
        try:
            self.assertEqual(attach.pidfd_gid(fd), os.getgid())
        finally:
            os.close(fd)

    def test_flatpak_name(self):
        self.assertEqual(attach.flatpak_name("[Application]\nname=x\n[Instance]\nname=y\n"), "x")


class ExactPath(unittest.TestCase):
    """A granted folder is opened as named: a symlink swapped in for it (or for
    any folder above it) after the user approved the path is refused."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.realpath(self.tmp.name)
        os.makedirs(os.path.join(self.root, "home/proj"))
        os.makedirs(os.path.join(self.root, "secret/.config"))

    def tearDown(self):
        self.tmp.cleanup()

    def opened(self, path):
        fd = attach.open_exact(path)
        try:
            return os.fstat(fd)
        finally:
            os.close(fd)

    def test_opens_the_folder(self):
        st = self.opened(os.path.join(self.root, "home/proj"))
        self.assertEqual((st.st_dev, st.st_ino), (lambda s: (s.st_dev, s.st_ino))(os.stat(os.path.join(self.root, "home/proj"))))

    def test_folder_swapped_for_a_symlink(self):
        proj = os.path.join(self.root, "home/proj")
        os.rmdir(proj)
        os.symlink(os.path.join(self.root, "secret/.config"), proj)
        with self.assertRaises(attach.Refused):
            attach.open_exact(proj)

    def test_parent_swapped_for_a_symlink(self):
        os.makedirs(os.path.join(self.root, "secret/.config/proj"))
        home = os.path.join(self.root, "home")
        os.rename(home, os.path.join(self.root, "home.old"))
        os.symlink(os.path.join(self.root, "secret/.config"), home)
        with self.assertRaises(attach.Refused):
            attach.open_exact(os.path.join(home, "proj"))

    def test_relative_symlink(self):
        os.symlink("../secret", os.path.join(self.root, "home/link"))
        with self.assertRaises(attach.Refused):
            attach.open_exact(os.path.join(self.root, "home/link"))

    def test_not_a_folder(self):
        f = os.path.join(self.root, "home/file")
        open(f, "w").close()
        with self.assertRaises(OSError):
            attach.open_exact(f)

    def test_canonical_only(self):
        for bad in ("rel/x", "/home/u/../etc", "/home/u/./x", "/home/u/x/", "//home/u/x", "/home//u", "/home/u\0x", None, 3):
            with self.assertRaises(attach.Refused, msg=repr(bad)):
                attach.canonical(bad)
        self.assertEqual(attach.canonical("/home/u/x"), "/home/u/x")

    def test_home_path(self):
        user = {"home": "/home/u"}
        self.assertEqual(attach.home_path(user, "/home/u/x"), "/home/u/x")
        for bad in ("/home/u", "/home/user2/x", "/home/u/../../etc", "/etc"):
            with self.assertRaises(attach.Refused, msg=bad):
                attach.home_path(user, bad)


class AllowIp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        self.log = os.path.join(d, "calls")
        fake = os.path.join(d, "systemctl")
        # A systemctl that logs its arguments; units named *-stopped are inactive.
        with open(fake, "w") as f:
            f.write(
                "#!/bin/sh\n"
                f"printf '%s ' \"$@\" >> {self.log}; echo >> {self.log}\n"
                'if [ "$1" = show ]; then\n'
                '  for a; do u="$a"; done\n'
                '  case "$u" in *-stopped*) echo inactive ;; *) echo active ;; esac\n'
                "fi\n"
            )
        os.chmod(fake, 0o755)
        self.cfg = {
            "systemctl": fake,
            "netUnits": {
                "vm-blender": ["sandbox-vm-blender-net@*.service"],
                "zoom": ["sandbox-zoom.service"],
            },
        }

    def tearDown(self):
        self.tmp.cleanup()

    def calls(self):
        try:
            with open(self.log) as f:
                return [l.split() for l in f.read().splitlines()]
        except FileNotFoundError:
            return []

    def req(self, sandbox, unit, addr):
        return attach.op_allow_ip(self.cfg, {"op": "allow-ip", "sandbox": sandbox, "unit": unit, "addr": addr})

    def test_adds_to_ip_address_allow_only(self):
        self.req("zoom", "sandbox-zoom.service", "192.0.2.7")
        self.req("vm-blender", "sandbox-vm-blender-net@home-u-x\\x2dy.service", "2001:db8::/32")
        sets = [c for c in self.calls() if c[0] == "set-property"]
        self.assertEqual(
            sets,
            [
                ["set-property", "--runtime", "--", "sandbox-zoom.service", "IPAddressAllow=192.0.2.7/32"],
                ["set-property", "--runtime", "--", "sandbox-vm-blender-net@home-u-x\\x2dy.service", "IPAddressAllow=2001:db8::/32"],
            ],
        )

    def test_refuses_other_units_and_sandboxes(self):
        for sandbox, unit in (
            ("zoom", "sandbox-other.service"),
            ("zoom", "sandbox-vm-blender-net@x.service"),  # another sandbox's
            ("vm-blender", "sandbox-vm-blender-net@x.service IPAddressDeny=any"),
            ("vm-blender", "sandbox-vm-blender-net@x/y.service"),
            ("unknown", "sandbox-zoom.service"),
            ("zoom", ["sandbox-zoom.service"]),
        ):
            with self.assertRaises(attach.Refused, msg=f"{sandbox} {unit}"):
                self.req(sandbox, unit, "192.0.2.7")
        self.assertEqual(self.calls(), [])

    def test_refuses_anything_but_an_address(self):
        # Never an empty assignment (a reset) or a keyword.
        for addr in ("", "any", "localhost", "192.0.2.7 10.0.0.0/8", "IPAddressDeny=", None):
            with self.assertRaises(attach.Refused, msg=repr(addr)):
                self.req("zoom", "sandbox-zoom.service", addr)
        self.assertEqual(self.calls(), [])

    def test_refuses_a_stopped_unit(self):
        self.cfg["netUnits"]["zoom"] = ["sandbox-zoom*.service"]
        with self.assertRaises(attach.Refused):
            self.req("zoom", "sandbox-zoom-stopped.service", "192.0.2.7")
        self.assertEqual([c[0] for c in self.calls()], ["show"])


class VmPath(unittest.TestCase):
    cfg = {"user": {"name": "u", "uid": os.getuid(), "gid": os.getgid(), "home": "/home/u"}, "vms": {"blender": "sbx-vm-blender"}}

    def test_unknown_vm(self):
        with self.assertRaises(attach.Refused):
            attach.op_vm_path(self.cfg, {"op": "vm-path", "vm": "other", "rtdir": "/run/sandbox-vm/other/main", "path": "/home/u/x"})

    def test_non_canonical_path(self):
        for path in ("/home/u/../../etc", "/home/u/x/", "/home/u/./x", "/etc/x", "x"):
            with self.assertRaises(attach.Refused, msg=path):
                attach.op_vm_path(self.cfg, {"op": "vm-path", "vm": "blender", "rtdir": "/run/sandbox-vm/blender/main", "path": path})

    def test_rtdir_outside_the_vm(self):
        for rtdir in ("/run/sandbox-vm/other/main", "/run/sandbox-vm/blender/../other/main", "/tmp/x"):
            with self.assertRaises(attach.Refused):
                attach.vm_targets(self.cfg, "blender", rtdir, 1234, wait=0)

    def flow(self, fail_idmap=False, targets=1, write=True, guarded=None):
        """op_vm_path with the privileged calls mocked: (attrs set, attach
        calls). The VM's uid is the user's + 1. `guarded`: a list the git
        guard's calls are recorded in (otherwise it runs, on "/")."""
        attrs, attached = [], []
        vm_pw = mock.Mock(pw_uid=os.getuid() + 1, pw_gid=os.getgid() + 1)

        def setattr_(fd, attr, userns_fd=0):
            if attr & attach.MOUNT_ATTR_IDMAP and fail_idmap:
                raise OSError(22, "Invalid argument")
            attrs.append((attr, userns_fd))

        maps = []

        def userns(uids, gids):
            maps.append((uids, gids))
            return os.open("/", os.O_RDONLY)

        with mock.patch.object(attach, "open_as_user", lambda u, p: os.open("/", os.O_PATH)), mock.patch.object(
            attach, "open_tree", lambda fd, recursive: os.dup(fd)
        ), mock.patch.object(attach, "mount_setattr", setattr_), mock.patch.object(
            attach, "idmap_userns", userns
        ), mock.patch.object(attach.pwd, "getpwnam", lambda n: vm_pw), mock.patch.object(
            attach,
            "vm_targets",
            lambda cfg, vm, rtdir, owner: [os.open("/", os.O_RDONLY) for _ in range(targets)] if owner == vm_pw.pw_uid else [],
        ), mock.patch.object(
            attach, "attach", lambda pidfd, tree, rel, is_dir, owner, rdev=None: attached.append((tree, rel, owner)) or True
        ), mock.patch.object(attach, "drop_to_user", lambda user: None), mock.patch.object(
            attach,
            "guard_git",
            attach.guard_git if guarded is None else lambda tree, lookup, path: guarded.append((len(attrs), path)) or [],
        ):
            n = attach.op_vm_path(
                self.cfg,
                {"op": "vm-path", "vm": "blender", "rtdir": "/run/sandbox-vm/blender/main", "path": "/home/u/x", "write": write},
            )
        return n, attrs, attached, maps

    def test_git_guard_on_writable_grants(self):
        """Each clone of a read-write grant gets the git guard before its
        attributes and idmap (so they cover its mounts); a read-only one
        doesn't need it."""
        guarded = []
        self.flow(targets=2, guarded=guarded)
        # The idmap check's clone, then one per target, each before its setattrs.
        self.assertEqual(guarded, [(0, "/home/u/x"), (2, "/home/u/x"), (4, "/home/u/x")])
        guarded.clear()
        self.flow(write=False, guarded=guarded)
        self.assertEqual(guarded, [])

    def test_idmapped_onto_the_vm(self):
        n, attrs, attached, maps = self.flow()
        self.assertEqual(n, 1)
        me, mg = os.getuid(), os.getgid()
        # Once to check it can be idmapped at all, once for the target.
        self.assertEqual(maps, [([(me, me + 1)], [(mg, mg + 1)])] * 2)
        self.assertEqual([a[0] for a in attrs], [attach.MOUNT_ATTR_NOSUID | attach.MOUNT_ATTR_NODEV, attach.MOUNT_ATTR_IDMAP] * 2)
        self.assertGreater(attrs[1][1], 0)
        self.assertEqual([a[1:] for a in attached], [("/x", me + 1)])

    def test_a_clone_per_target(self):
        """A detached tree can be mounted once: every running instance gets
        its own clone, each set up (read-only, idmapped) the same."""
        n, attrs, attached, maps = self.flow(targets=3)
        self.assertEqual(n, 3)
        self.assertEqual(len(attached), 3)
        self.assertEqual(len(maps), 4)
        self.assertEqual(len(attrs), 8)

    def test_not_idmappable_is_refused(self):
        with self.assertRaises(attach.Refused):
            self.flow(fail_idmap=True)


class PathGuard(unittest.TestCase):
    """op_path: a read-write folder grant's clone gets the git guard before
    its attributes; a read-only one doesn't."""

    def run_op(self, write):
        cfg = {"user": {"name": "u", "uid": os.getuid(), "gid": os.getgid(), "home": "/home/u"}}
        calls = []

        def attach_all(pidfds, clone, path, is_dir, owner):
            os.close(clone())
            return 1

        with mock.patch.object(attach, "open_as_user", lambda u, p: os.open("/", os.O_PATH)), mock.patch.object(
            attach, "open_tree", lambda fd, recursive: os.dup(fd)
        ), mock.patch.object(attach, "mount_setattr", lambda fd, attr: calls.append(("setattr", attr))), mock.patch.object(
            attach, "targets", lambda cfg, sb, name: [0]
        ), mock.patch.object(attach, "attach_all", attach_all), mock.patch.object(
            attach, "guard_git", lambda tree, lookup, path: calls.append(("guard", path)) or []
        ):
            attach.op_path(cfg, {"paths": True}, "app", {"op": "path", "sandbox": "app", "path": "/home/u/proj", "write": write})
        return calls

    def test_guarded_when_writable(self):
        base = attach.MOUNT_ATTR_NOSUID | attach.MOUNT_ATTR_NODEV
        self.assertEqual(self.run_op(True), [("guard", "/home/u/proj"), ("setattr", base)])
        self.assertEqual(self.run_op(False), [("setattr", base | attach.MOUNT_ATTR_RDONLY)])


class Idmap(unittest.TestCase):
    def test_lines(self):
        self.assertEqual(attach.idmap_lines([(1000, 987)]), "1000 987 1\n")
        for bad in ([], [(1, 2), (1, 3)], [(1, 2), (3, 2)], [(-1, 2)], [("1", 2)], [(False, 2)]):
            with self.assertRaises(attach.Refused, msg=repr(bad)):
                attach.idmap_lines(bad)

    def test_userns(self):
        me, mg = os.getuid(), os.getgid()
        try:
            fd = attach.idmap_userns([(me, me)], [(mg, mg)])
        except (attach.Refused, PermissionError) as e:
            self.skipTest(f"no unprivileged user namespaces here: {e}")
        try:
            self.assertNotEqual(os.readlink(f"/proc/self/fd/{fd}"), os.readlink("/proc/self/ns/user"))
        finally:
            os.close(fd)

    def test_never_onto_root_or_the_user(self):
        from unittest import mock

        user = {"uid": 1000, "gid": 100}
        for uid, gid in ((0, 5), (5, 0), (1000, 5), (5, 100)):
            with self.assertRaises(attach.Refused):
                attach.idmap_to(-1, user, mock.Mock(pw_uid=uid, pw_gid=gid), "/home/u/x")


def load_grants():
    spec = importlib.util.spec_from_file_location("grants", os.path.join(HERE, "..", "..", "vm", "grants.py"))
    grants = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(grants)
    return grants


class Sealed(unittest.TestCase):
    """What runs as root inside a sandbox's mount namespace (after setns) is
    sealed: it can't load code from a file, whose path would name the
    sandbox's. Each case runs in a fresh `python3 -IS` (as the helper does),
    so only attach.py's own imports are loaded."""

    def run_sealed(self, body):
        script = (
            "import os, sys\n"
            f"ns = {{'__name__': 'attach'}}\n"
            f"exec(compile(open({os.path.join(HERE, '..', 'attach.py')!r}).read(), 'attach.py', 'exec'), ns)\n"
            # attach.X reads and sets the module's globals.
            "class A:\n"
            "    __getattr__ = lambda self, k: ns[k]\n"
            "    __setattr__ = lambda self, k, v: ns.__setitem__(k, v)\n"
            "attach = A()\n"
            + body
        )
        r = subprocess.run([sys.executable, "-I", "-S", "-c", script], capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.split()

    def test_nothing_loads(self):
        out = self.run_sealed(
            "attach.seal()\n"
            "def tried(f):\n"
            "    try:\n"
            "        f()\n"
            "    except (ImportError, PermissionError):\n"
            "        return 'refused'\n"
            "    return 'loaded'\n"
            "import importlib\n"
            "print(tried(lambda: importlib.import_module('decimal')))\n"  # a .py module
            "print(tried(lambda: importlib.import_module('_csv')))\n"  # an extension module
            "print(tried(lambda: attach.ctypes.CDLL('libm.so.6')))\n"
            "print(tried(lambda: attach.subprocess.run(['true'])))\n"
            "print(tried(lambda: os.execv('/bin/true', ['true'])))\n"
            "print(tried(lambda: os.posix_spawn('/bin/true', ['true'], {})))\n"
        )
        self.assertEqual(out, ["refused"] * 6)

    def test_mount_in_needs_nothing_more(self):
        """attach's part in the sandbox (mount point by a dropped child, fd
        passing back, the mount) runs sealed: no lazy import on the way, the
        one in socket.recv_fds included. The uid drop and the mount itself
        need root, so they're stubbed."""
        with tempfile.TemporaryDirectory() as tmp:
            if attach.statfs_type(os.open(tmp, os.O_PATH)) != attach.TMPFS_MAGIC:
                self.skipTest("TMPDIR must be on a tmpfs")
            null = os.stat("/dev/null").st_rdev
            out = self.run_sealed(
                "os.setgroups = os.setresgid = os.setresuid = lambda *a: None\n"
                "attach.move_mount = lambda tree, dst: print('mounted')\n"
                "attach.seal()\n"
                f"print(attach.mount_in(-1, {os.path.realpath(tmp) + '/a/b'!r}, True, os.getuid(), os.getgid(), None).decode())\n"
                f"print(attach.mount_in(-1, '/dev/null', False, os.getuid(), os.getgid(), {null}).decode())\n"
            )
            self.assertTrue(os.path.isdir(os.path.join(tmp, "a", "b")))
        self.assertEqual(out, ["mounted", "ok", "already"])


class GuestMount(unittest.TestCase):
    """The guest agent (root in the guest) walks the share and the target
    without following a symlink and mounts onto what it opened; the bind
    itself (open_tree/move_mount) needs root."""

    def setUp(self):
        self.grants = load_grants()
        self.tmp = tempfile.TemporaryDirectory()
        self.d = os.path.realpath(self.tmp.name)
        self.home = os.path.join(self.d, "home")
        self.share = os.path.join(self.d, "share")
        os.makedirs(os.path.join(self.share, "Documents", "x"))
        os.makedirs(os.path.join(self.home, "Documents"))
        os.makedirs(os.path.join(self.d, "etc"))
        self.owner = (self.home, os.getuid(), os.getgid())
        self.binds = []

    def tearDown(self):
        self.tmp.cleanup()

    def bind(self, src, dst, ro):
        self.binds.append((os.readlink(f"/proc/self/fd/{src}"), os.readlink(f"/proc/self/fd/{dst}"), ro))

    def mount(self, rel, path, ro=False):
        self.grants.guest_mount(self.share, self.owner, rel, path, ro, bind=self.bind)

    def test_mounts_onto_what_it_walked(self):
        self.mount("/Documents/x", os.path.join(self.home, "Documents", "x", "y"), ro=True)
        target = os.path.join(self.home, "Documents", "x", "y")
        self.assertEqual(self.binds, [(os.path.join(self.share, "Documents", "x"), target, True)])
        self.assertTrue(os.path.isdir(target))
        self.assertEqual(os.stat(target).st_uid, os.getuid())

    def test_planted_symlink_in_the_target(self):
        os.symlink(os.path.join(self.d, "etc"), os.path.join(self.home, "Documents", "x"))
        for path in (os.path.join(self.home, "Documents", "x"), os.path.join(self.home, "Documents", "x", "y")):
            with self.assertRaises(ValueError, msg=path):
                self.mount("/Documents/x", path)
        self.assertEqual(self.binds, [])
        self.assertEqual(os.listdir(os.path.join(self.d, "etc")), [])

    def test_planted_symlink_in_the_share(self):
        os.rename(os.path.join(self.share, "Documents"), os.path.join(self.share, "real"))
        os.symlink(os.path.join(self.d, "etc"), os.path.join(self.share, "Documents"))
        with self.assertRaises(ValueError):
            self.mount("/Documents/x", os.path.join(self.home, "Documents", "x"))
        self.assertEqual(self.binds, [])

    def test_only_inside_the_home(self):
        for path in (os.path.join(self.d, "etc"), self.home, self.home + "/../etc", self.home + "/a/", "rel"):
            with self.assertRaises(ValueError, msg=path):
                self.mount("/Documents/x", path)
        for rel in ("Documents/x", "/Documents/../../etc", "/Documents//x"):
            with self.assertRaises(ValueError, msg=rel):
                self.mount(rel, os.path.join(self.home, "Documents", "x"))
        self.assertEqual(self.binds, [])

    def test_missing_source(self):
        with self.assertRaises(FileNotFoundError):
            self.mount("/Documents/nope", os.path.join(self.home, "Documents", "nope"))
        self.assertFalse(os.path.exists(os.path.join(self.home, "Documents", "nope")))


class Hub(unittest.TestCase):
    def test_share_names_the_launch_as_the_host_does(self):
        grants = load_grants()
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "args")
            fake = os.path.join(d, "attach")
            with open(fake, "w") as f:
                f.write(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > {log}\n")
            os.chmod(fake, 0o755)
            hub = grants.Hub("/home/u", "/run/sandbox-vm/nv/run/grants", fake, "nv", "/run/sandbox-vm/nv/0123456789abcdef")
            hub.share("/home/u/x", "rw")
            with open(log) as f:
                self.assertEqual(f.read().split("\n")[2], "/run/sandbox-vm/nv/0123456789abcdef")

    def test_share_asks_the_attach_helper(self):
        grants = load_grants()
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "args")
            fake = os.path.join(d, "attach")
            with open(fake, "w") as f:
                f.write(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > {log}\n")
            os.chmod(fake, 0o755)
            hub = grants.Hub("/home/u", "/run/sandbox-vm/blender/main/grants", fake, "blender")
            hub.share("/home/u/Documents/x", "ro")
            with open(log) as f:
                self.assertEqual(
                    f.read().split("\n")[:-1],
                    ["vm", "blender", "/run/sandbox-vm/blender/main", "/home/u/Documents/x", "ro"],
                )

    def test_grant_takes_the_path_as_given(self):
        """The hub never resolves the path again (a symlink swapped in after
        the user's approval would be followed); a non-canonical one is refused
        before anything is shared."""
        grants = load_grants()
        with tempfile.TemporaryDirectory() as d:
            home = os.path.realpath(d)
            log = os.path.join(d, "args")
            fake = os.path.join(d, "attach")
            with open(fake, "w") as f:
                f.write(f"#!/bin/sh\nprintf '%s\\n' \"$@\" >> {log}\nexit 1\n")
            os.chmod(fake, 0o755)
            os.makedirs(os.path.join(home, ".config"))
            os.symlink(os.path.join(home, ".config"), os.path.join(home, "proj"))
            hub = grants.Hub(home, "/run/sandbox-vm/blender/main/grants", fake, "blender")
            for bad in (f"{home}/x/../.config", f"{home}/proj/", f"{home}//proj", "/etc", home):
                with self.assertRaises(ValueError, msg=bad):
                    hub.grant(bad, "rw")
            self.assertFalse(os.path.exists(log))
            # The symlink goes to the helper by its own name, not its target's
            # (which the helper then refuses to open).
            with self.assertRaises(RuntimeError):
                hub.grant(f"{home}/proj", "rw")
            with open(log) as f:
                self.assertEqual(f.read().split("\n")[3], f"{home}/proj")

    def test_guest_that_never_answers(self):
        """A guest agent that doesn't answer is dropped after the timeout, and
        the next grant isn't held up behind it."""
        grants = load_grants()
        grants.GUEST_TIMEOUT = 0.5
        import socket
        with tempfile.TemporaryDirectory() as d:
            fake = os.path.join(d, "attach")
            with open(fake, "w") as f:
                f.write("#!/bin/sh\nexit 0\n")
            os.chmod(fake, 0o755)
            hub = grants.Hub("/home/u", os.path.join(d, "grants"), fake, "blender")
            host, guest = socket.socketpair()
            hub.guest = (host, host.makefile("rb"))
            with self.assertRaises(RuntimeError):
                hub.grant("/home/u/x", "rw")
            self.assertIsNone(hub.guest)
            self.assertTrue(hub.lock.acquire(timeout=0))
            hub.lock.release()
            # A new agent connection then serves the next grant.
            host2, guest2 = socket.socketpair()
            hub.guest = (host2, host2.makefile("rb"))
            gf = guest2.makefile("rb")

            def agent():
                req = json.loads(gf.readline())
                guest2.sendall((json.dumps({"ok": req["path"] == "/home/u/y"}) + "\n").encode())

            import threading
            t = threading.Thread(target=agent)
            t.start()
            hub.grant("/home/u/y", "ro")
            t.join()
            self.assertEqual(hub.granted, [("/home/u/y", "ro")])
            for sock in (guest, guest2, host2):
                sock.close()


M = attach

# ── The git guard ────────────────────────────────────────────────────────────


def run_git(*args, cwd):
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", HOME=cwd)
    subprocess.run(
        ["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main", *args],
        cwd=cwd,
        env=env,
        check=True,
        capture_output=True,
    )


class GitGuardCalls(unittest.TestCase):
    """guard_git with the mounts mocked: what is mounted onto what, in which
    order (.git pinned first, then each entry read-only inside the pin)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.r = os.path.join(os.path.realpath(self.tmp.name), "r")
        os.makedirs(self.r)
        self.calls = []
        RO = M.MOUNT_ATTR_RDONLY
        for name, fn in (
            ("open_tree", lambda fd, recursive: os.dup(fd)),
            ("move_mount", lambda tree, dst: self.calls.append(("mount", self.rel(dst)))),
            ("mount_setattr", lambda fd, attr_set=0, **k: self.calls.append(("ro" if attr_set & RO else "attr", self.rel(fd)))),
        ):
            pt = mock.patch.object(M, name, fn)
            pt.start()
            self.addCleanup(pt.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def rel(self, fd):
        return os.path.relpath(os.readlink(f"/proc/self/fd/{fd}"), self.r)

    def git_dir(self, *entries):
        os.makedirs(os.path.join(self.r, ".git", "objects"))
        for e in entries:
            if e.endswith("/"):
                os.makedirs(os.path.join(self.r, ".git", e))
            else:
                open(os.path.join(self.r, ".git", e), "w").close()

    def guard(self):
        fd = os.open(self.r, os.O_PATH | os.O_DIRECTORY)
        try:
            return M.guard_git(fd, M.git_entry, self.r)
        finally:
            os.close(fd)

    def test_not_a_repo(self):
        self.assertEqual(self.guard(), [])
        self.assertEqual(self.calls, [])

    def test_repo(self):
        self.git_dir("config", "hooks/")
        self.assertEqual(self.guard(), [".git", ".git/config", ".git/hooks"])
        self.assertEqual(
            self.calls,
            [("mount", ".git"), ("ro", ".git/config"), ("mount", ".git/config"), ("ro", ".git/hooks"), ("mount", ".git/hooks")],
        )

    def test_every_entry(self):
        self.git_dir("config", "config.worktree", "commondir", "hooks/")
        self.assertEqual(self.guard(), [".git", ".git/config", ".git/config.worktree", ".git/commondir", ".git/hooks"])

    def test_missing_entries_not_made(self):
        """Nothing is made for a missing config or commondir (a mount needs an
        existing target, and one left on disk would break the host's git)."""
        self.git_dir("hooks/")
        self.assertEqual(self.guard(), [".git", ".git/hooks"])
        self.assertEqual(sorted(os.listdir(os.path.join(self.r, ".git"))), ["hooks", "objects"])

    def test_missing_hooks_made_empty(self):
        self.git_dir("config")
        self.assertEqual(self.guard(), [".git", ".git/config", ".git/hooks"])
        self.assertEqual(os.listdir(os.path.join(self.r, ".git", "hooks")), [])

    def test_hooks_not_made_in_someone_elses(self):
        self.git_dir("config")
        with mock.patch.object(M.os, "geteuid", lambda: os.getuid() + 1):
            self.assertEqual(self.guard(), [".git", ".git/config"])
        self.assertFalse(os.path.exists(os.path.join(self.r, ".git", "hooks")))

    def test_worktree_file(self):
        with open(os.path.join(self.r, ".git"), "w") as f:
            f.write("gitdir: /elsewhere/.git/worktrees/r\n")
        self.assertEqual(self.guard(), [".git"])
        self.assertEqual(self.calls, [("ro", ".git"), ("mount", ".git")])

    def test_symlinks_left_alone(self):
        os.makedirs(os.path.join(self.r, "real"))
        os.symlink("real", os.path.join(self.r, ".git"))
        self.assertEqual(self.guard(), [])
        self.assertEqual(self.calls, [])
        os.unlink(os.path.join(self.r, ".git"))
        self.git_dir("hooks/")
        os.symlink("../real", os.path.join(self.r, ".git", "config"))
        self.assertEqual(self.guard(), [".git", ".git/hooks"])

    def test_lookup_errors_fail(self):
        """Anything but "missing" or "a symlink" fails the guard (the share is
        then refused)."""
        self.git_dir("config", "hooks/")

        def lookup(dir_fd, name, make_dir=False):
            if name == "config":
                raise M.Refused("[Errno 13] Permission denied")
            return M.git_entry(dir_fd, name, make_dir)

        fd = os.open(self.r, os.O_PATH | os.O_DIRECTORY)
        try:
            with self.assertRaises(M.Refused):
                M.guard_git(fd, lookup, self.r)
        finally:
            os.close(fd)


class GitGuardMounted(unittest.TestCase):
    """guard_git for real, in a user and mount namespace of our own: the
    sandbox's view of the repo can commit, but not change its config or hooks
    or move its .git; nothing is left on disk."""

    def test_in_a_namespace(self):
        if shutil.which("git") is None:
            self.skipTest("no git")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        d = os.path.realpath(tmp.name)
        repo, dst = os.path.join(d, "repo"), os.path.join(d, "dst")
        os.makedirs(repo)
        os.makedirs(dst)
        run_git("init", "-q", "--template=", cwd=repo)  # no hooks folder
        run_git("commit", "-q", "--allow-empty", "-m", "one", cwd=repo)
        with open(os.path.join(repo, ".git", "config")) as f:
            config = f.read()
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            res = {}
            try:
                uid, gid = os.getuid(), os.getgid()
                try:
                    os.unshare(os.CLONE_NEWUSER | os.CLONE_NEWNS)
                except OSError as e:
                    res["skip"] = str(e)
                    raise
                for f, text in (("setgroups", "deny"), ("uid_map", f"0 {uid} 1"), ("gid_map", f"0 {gid} 1")):
                    with open(f"/proc/self/{f}", "w") as fh:
                        fh.write(text)
                src = os.open(repo, os.O_PATH | os.O_DIRECTORY)
                tree = M.open_tree(src, True)
                res["done"] = M.guard_git(tree, M.git_entry, repo)
                M.mount_setattr(tree, M.MOUNT_ATTR_NOSUID | M.MOUNT_ATTR_NODEV)
                target = os.open(dst, os.O_PATH | os.O_DIRECTORY)
                M.move_mount(tree, target)
                g = os.path.join(dst, ".git")

                def attempt(key, fn):
                    try:
                        fn()
                        res[key] = "ok"
                    except OSError as e:
                        res[key] = errno.errorcode.get(e.errno, str(e.errno))
                    except subprocess.CalledProcessError as e:
                        res[key] = "failed: " + e.stderr.decode(errors="replace").strip()

                def replace_config():
                    with open(os.path.join(g, "config.lock"), "w") as fh:
                        fh.write("[core]\n\tfsmonitor = evil\n")
                    try:
                        os.rename(os.path.join(g, "config.lock"), os.path.join(g, "config"))
                    finally:
                        os.unlink(os.path.join(g, "config.lock"))

                attempt("append config", lambda: open(os.path.join(g, "config"), "a").write("x"))
                attempt("replace config", replace_config)
                attempt("new hook", lambda: open(os.path.join(g, "hooks", "pre-commit"), "w").write("x"))
                attempt("remove hooks", lambda: os.rmdir(os.path.join(g, "hooks")))
                attempt("move .git", lambda: os.rename(g, os.path.join(dst, ".gitx")))
                attempt("git config", lambda: run_git("config", "core.fsmonitor", "evil", cwd=dst))
                attempt("commit", lambda: run_git("commit", "-q", "--allow-empty", "-m", "two", cwd=dst))
                attempt("branch", lambda: run_git("branch", "feature", cwd=dst))
            except BaseException as e:
                res.setdefault("error", repr(e))
            os.write(w, json.dumps(res).encode())
            os._exit(0)
        os.close(w)
        out = b""
        while chunk := os.read(r, 65536):
            out += chunk
        os.close(r)
        os.waitpid(pid, 0)
        res = json.loads(out)
        if "skip" in res:
            self.skipTest(f"no unprivileged user namespaces here: {res['skip']}")
        self.assertNotIn("error", res, res.get("error"))
        self.assertEqual(res["done"], [".git", ".git/config", ".git/hooks"])
        self.assertEqual(res["append config"], "EROFS")
        self.assertEqual(res["replace config"], "EBUSY")
        self.assertEqual(res["new hook"], "EROFS")
        self.assertIn(res["remove hooks"], ("EBUSY", "EROFS"))
        self.assertEqual(res["move .git"], "EBUSY")
        self.assertTrue(res["git config"].startswith("failed"), res["git config"])
        self.assertEqual(res["commit"], "ok")
        self.assertEqual(res["branch"], "ok")
        # On disk: the config as it was, the commit and branch there, the
        # (empty) hooks folder made, nothing else left behind.
        with open(os.path.join(repo, ".git", "config")) as f:
            self.assertEqual(f.read(), config)
        self.assertEqual(os.listdir(os.path.join(repo, ".git", "hooks")), [])
        for name in ("commondir", "config.worktree", "config.lock"):
            self.assertFalse(os.path.exists(os.path.join(repo, ".git", name)), name)
        log = subprocess.run(["git", "-C", repo, "log", "--format=%s"], capture_output=True, text=True, check=True).stdout
        self.assertEqual(log.split(), ["two", "one"])
        self.assertEqual(os.listdir(dst), [])


if __name__ == "__main__":
    unittest.main()
