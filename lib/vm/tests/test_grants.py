"""Unprivileged tests for lib/vm/grants.py (sbx-grants): the hub's sockets
appear only with their final mode, and the guest agent's walk makes missing
folders under the home and hands them over by fd, never through a name the
user could have swapped. The mounts need root and a real VM.

  python3 -m unittest discover -s lib/vm/tests -p 'test_grants.py'
"""

import importlib.util
import os
import socket
import stat
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("grants", os.path.join(HERE, "..", "grants.py"))
grants = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grants)


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = os.path.realpath(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def p(self, *parts):
        return os.path.join(self.d, *parts)


class Listen(Tmp):
    def test_final_mode_only(self):
        """The name appears listening and 0600 (an ACL set on it from then on
        stays), with no temporary name left behind; a stale one is replaced."""
        path = self.p("guest.sock")
        open(path, "w").close()
        open(path + ".new", "w").close()
        seen = []
        real_rename = os.rename

        def rename(a, b):
            # Before the rename the final name isn't there yet.
            seen.append(os.path.exists(b))
            real_rename(a, b)

        with mock.patch.object(grants.os, "rename", rename):
            s = grants.listen(path)
        self.addCleanup(s.close)
        self.assertEqual(seen, [False])
        st = os.lstat(path)
        self.assertTrue(stat.S_ISSOCK(st.st_mode))
        self.assertEqual(stat.S_IMODE(st.st_mode), 0o600)
        self.assertFalse(os.path.exists(path + ".new"))
        c = socket.socket(socket.AF_UNIX)
        self.addCleanup(c.close)
        c.connect(path)


class Walk(Tmp):
    def setUp(self):
        super().setUp()
        os.makedirs(self.p("home", "u"))
        self.home = self.p("home", "u")

    def test_creates_and_hands_over_by_fd(self):
        chowned = []
        with (
            mock.patch.object(grants.os, "chown", lambda *a, **k: self.fail("chown by name")),
            mock.patch.object(grants.os, "fchown", lambda fd, uid, gid: chowned.append((uid, gid))),
        ):
            fd = grants.walk(f"{self.home}/a/b", create=(self.home, 1234, 5678))
        os.close(fd)
        self.assertTrue(os.path.isdir(self.p("home", "u", "a", "b")))
        self.assertEqual(chowned, [(1234, 5678), (1234, 5678)])

    def test_swapped_for_a_link(self):
        """A link put where the new folder was is never followed or chowned."""
        os.makedirs(self.p("target"))
        real_mkdir = os.mkdir

        def mkdir(name, mode, dir_fd):
            real_mkdir(name, mode, dir_fd=dir_fd)
            os.rmdir(name, dir_fd=dir_fd)
            os.symlink(self.p("target"), name, dir_fd=dir_fd)

        with (
            mock.patch.object(grants.os, "mkdir", mkdir),
            mock.patch.object(grants.os, "fchown", lambda *a: self.fail("chowned")),
        ):
            with self.assertRaises(OSError):
                grants.walk(f"{self.home}/a", create=(self.home, 1234, 5678))

    def test_swapped_for_someone_elses(self):
        """A folder of another owner put in its place isn't handed over."""
        real_mkdir = os.mkdir

        def mkdir(name, mode, dir_fd):
            real_mkdir(name, mode, dir_fd=dir_fd)

        with (
            mock.patch.object(grants.os, "mkdir", mkdir),
            mock.patch.object(grants.os, "geteuid", lambda: os.getuid() + 1),
            mock.patch.object(grants.os, "fchown", lambda *a: self.fail("chowned")),
        ):
            with self.assertRaises(ValueError):
                grants.walk(f"{self.home}/a", create=(self.home, 1234, 5678))

    def test_outside_the_home_not_handed_over(self):
        with mock.patch.object(grants.os, "fchown", lambda *a: self.fail("chowned")):
            os.close(grants.walk(self.p("elsewhere", "x"), create=(self.home, 1234, 5678)))


if __name__ == "__main__":
    unittest.main()
