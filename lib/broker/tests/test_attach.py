"""Unprivileged tests for lib/broker/attach.py: the record parsing and the
symlink-safe mount-point creation (the mounts themselves need root and a live
sandbox). Run with TMPDIR on a tmpfs: python3 -m unittest lib/broker/tests/test_attach.py"""

import importlib.util
import json
import os
import stat
import tempfile
import unittest

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
    cfg = {"user": {"uid": os.getuid(), "home": "/home/u"}, "vms": ["blender"]}

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
                attach.vm_targets(self.cfg, "blender", rtdir, wait=0)


def load_grants():
    spec = importlib.util.spec_from_file_location("grants", os.path.join(HERE, "..", "..", "vm", "grants.py"))
    grants = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(grants)
    return grants


class Hub(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
