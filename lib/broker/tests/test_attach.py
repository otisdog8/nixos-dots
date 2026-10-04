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
        self.rt = self.tmp.name
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

    def test_flatpak_name(self):
        self.assertEqual(attach.flatpak_name("[Application]\nname=x\n[Instance]\nname=y\n"), "x")


class VmPath(unittest.TestCase):
    cfg = {"user": {"uid": os.getuid(), "home": "/home/u"}, "vms": ["blender"]}

    def test_unknown_vm(self):
        with self.assertRaises(attach.Refused):
            attach.op_vm_path(self.cfg, {"op": "vm-path", "vm": "other", "rtdir": "/run/sandbox-vm/other/main", "path": "/home/u/x"})

    def test_rtdir_outside_the_vm(self):
        for rtdir in ("/run/sandbox-vm/other/main", "/run/sandbox-vm/blender/../other/main", "/tmp/x"):
            with self.assertRaises(attach.Refused):
                attach.vm_targets(self.cfg, "blender", rtdir, wait=0)


class Hub(unittest.TestCase):
    def test_share_asks_the_attach_helper(self):
        spec = importlib.util.spec_from_file_location("grants", os.path.join(HERE, "..", "..", "vm", "grants.py"))
        grants = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(grants)
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


if __name__ == "__main__":
    unittest.main()
