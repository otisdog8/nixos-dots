"""Unprivileged tests for lib/backends/mount-helper.py: the symlink-safe walk,
the graft mountpoint preparation, and the work-as-the-owner path (the forked,
privilege-dropped child that hands an fd back). The mounts themselves, and a
drop to ANOTHER uid, need root; here the child drops to our own uid, which
exercises the same fork / credential change / fd passing / error relay.
Run: python3 -m unittest lib/backends/tests/test_mount_helper.py"""

import importlib.util
import os
import socket
import stat
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("mount_helper", os.path.join(HERE, "..", "mount-helper.py"))
mh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mh)


class Base(unittest.TestCase):
    """A fake "/" (mh's `root`) with a stash and a home under it, so no walk
    crosses the real, world-writable /tmp."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.chmod(self.root, 0o755)
        os.makedirs(self.p("/stash/app/.config/app"), 0o700)
        os.makedirs(self.p("/home/app"), 0o700)
        with open(self.p("/stash/app/file"), "w"):
            pass

    def tearDown(self):
        mh._euid = os.geteuid
        self.tmp.cleanup()

    def p(self, path):
        return self.root + path

    def same_inode(self, fd, path):
        a, b = os.fstat(fd), os.stat(path, follow_symlinks=False)
        return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)


class Walk(Base):
    def test_opens_every_component(self):
        fd = mh.walk("/home/app", self.root)
        self.assertTrue(self.same_inode(fd, self.p("/home/app")))
        os.close(fd)

    def test_refuses_symlink_component(self):
        os.symlink(self.p("/stash"), self.p("/home/app/link"))
        with self.assertRaises(mh.Refuse):
            mh.walk("/home/app/link/app", self.root)

    def test_refuses_dotdot_and_relative(self):
        with self.assertRaises(mh.Refuse):
            mh.walk("/home/../stash", self.root)
        with self.assertRaises(mh.Refuse):
            mh.walk("home/app", self.root)

    def test_refuses_world_writable_dir(self):
        os.chmod(self.p("/home"), 0o777)
        with self.assertRaises(mh.Refuse):
            mh.walk("/home/app", self.root)

    def test_open_path_refuses_symlink_leaf(self):
        os.symlink(self.p("/stash/app/file"), self.p("/home/app/f"))
        with self.assertRaises(mh.Refuse):
            mh.open_path("/home/app/f", self.root)


class Graft(Base):
    def test_creates_parents_and_dir_leaf(self):
        sfd, dfd = mh.graft_fds("/stash/app/.config/app", "/home/app", ".config/app", "dir", root=self.root)
        self.assertTrue(self.same_inode(sfd, self.p("/stash/app/.config/app")))
        self.assertTrue(self.same_inode(dfd, self.p("/home/app/.config/app")))
        st = os.stat(self.p("/home/app/.config"))
        self.assertEqual(st.st_uid, os.geteuid())  # made by the owner of ~
        os.close(sfd)
        os.close(dfd)

    def test_file_leaf(self):
        sfd, dfd = mh.graft_fds("/stash/app/file", "/home/app", "a/b/file", "file", root=self.root)
        self.assertTrue(stat.S_ISREG(os.stat(self.p("/home/app/a/b/file")).st_mode))
        os.close(sfd)
        os.close(dfd)

    def test_self_heals_wrong_type(self):
        os.makedirs(self.p("/home/app/file"))
        _, dfd = mh.graft_fds("/stash/app/file", "/home/app", "file", "file", root=self.root)
        self.assertTrue(stat.S_ISREG(os.stat(self.p("/home/app/file")).st_mode))
        os.close(dfd)
        os.makedirs(self.p("/home/app/.config"))
        with open(self.p("/home/app/.config/app"), "w"):
            pass
        _, dfd = mh.graft_fds("/stash/app/.config/app", "/home/app", ".config/app", "dir", root=self.root)
        self.assertTrue(stat.S_ISDIR(os.stat(self.p("/home/app/.config/app")).st_mode))
        os.close(dfd)

    def test_refuses_symlinked_target(self):
        os.makedirs(self.p("/elsewhere"))
        os.symlink(self.p("/elsewhere"), self.p("/home/app/.config"))
        with self.assertRaises(mh.Refuse):
            mh.graft_fds("/stash/app/.config/app", "/home/app", ".config/app", "dir", root=self.root)
        os.unlink(self.p("/home/app/.config"))
        os.makedirs(self.p("/home/app/.config"))
        os.symlink(self.p("/elsewhere"), self.p("/home/app/.config/app"))
        with self.assertRaises(mh.Refuse):
            mh.graft_fds("/stash/app/.config/app", "/home/app", ".config/app", "dir", root=self.root)
        self.assertEqual(os.listdir(self.p("/elsewhere")), [])

    def test_refuses_wrong_stash_type(self):
        with self.assertRaises(mh.Refuse):
            mh.graft_fds("/stash/app/file", "/home/app", "x", "dir", root=self.root)

    def graft_as(self, uid, relpath):
        """graft_fds with chown_user resolving to `uid`; returns the chown calls
        (recorded, not made: chowning to anyone else needs root)."""
        calls = []
        getpwnam, chown_fd = mh.pwd.getpwnam, mh.chown_fd
        mh.pwd.getpwnam = lambda name: type("pw", (), {"pw_uid": uid})
        mh.chown_fd = lambda fd, to: calls.append((os.fstat(fd).st_ino, to))
        try:
            sfd, dfd = mh.graft_fds("/stash/app/file", "/home/app", relpath, "file", "app", root=self.root)
        finally:
            mh.pwd.getpwnam, mh.chown_fd = getpwnam, chown_fd
        os.close(sfd)
        os.close(dfd)
        return calls

    def test_no_chown_when_already_owned(self):
        self.assertEqual(self.graft_as(os.geteuid(), "a/b/file"), [])

    def test_chowns_each_foreign_intermediate(self):
        other = os.geteuid() + 1
        calls = self.graft_as(other, "a/b/file")
        inos = [os.stat(self.p(d)).st_ino for d in ("/home/app/a", "/home/app/a/b")]
        self.assertEqual(calls, [(i, other) for i in inos])


class Relay(Base):
    def test_socket_relay_and_owner_check(self):
        os.makedirs(self.p("/run/user/1"), 0o700)
        os.makedirs(self.p("/run/app"), 0o700)
        s = socket.socket(socket.AF_UNIX)
        s.bind(self.p("/run/user/1/bus"))
        with open(self.p("/run/app/bus"), "w"):
            pass
        try:
            sfd, dfd = mh.relay_fds("/run/user/1/bus", "/run/app/bus", "S", os.geteuid(), self.root)
            self.assertTrue(self.same_inode(sfd, self.p("/run/user/1/bus")))
            self.assertTrue(self.same_inode(dfd, self.p("/run/app/bus")))
            os.close(sfd)
            os.close(dfd)
            with self.assertRaises(mh.Refuse):
                mh.relay_fds("/run/user/1/bus", "/run/app/bus", "S", os.geteuid() + 1, self.root)
            with self.assertRaises(mh.Refuse):
                mh.relay_fds("/run/user/1/bus", "/run/app/bus", "d", os.geteuid(), self.root)
        finally:
            s.close()


class AsOwner(Base):
    """The child path, forced by making every directory look foreign."""

    def setUp(self):
        super().setUp()
        mh._euid = lambda: -1

    def test_child_opens_and_hands_back(self):
        fd = mh.walk("/home/app", self.root)
        self.assertTrue(self.same_inode(fd, self.p("/home/app")))
        os.close(fd)

    def test_child_creates_and_relays_errors(self):
        sfd, dfd = mh.graft_fds("/stash/app/.config/app", "/home/app", "x/y", "dir", root=self.root)
        self.assertTrue(self.same_inode(dfd, self.p("/home/app/x/y")))
        os.close(sfd)
        os.close(dfd)
        # FileNotFoundError (errno) and Refuse cross the process boundary intact.
        with self.assertRaises(FileNotFoundError):
            mh.walk("/home/missing", self.root)
        os.symlink("/", self.p("/home/app/link"))
        with self.assertRaises(mh.Refuse):
            mh.walk("/home/app/link", self.root)

    def test_in_child_runs_with_dropped_credentials(self):
        def probe(dir_fd, name):
            # Report the child's credentials through a file it creates.
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dir_fd)
            os.write(fd, f"{os.getresuid()} {os.getresgid()}".encode())
            os.close(fd)
            return None

        dfd = mh.open_root(self.p("/home/app"))
        self.assertIsNone(mh.in_child(os.geteuid(), os.getegid(), dfd, probe, "who"))
        os.close(dfd)
        with open(self.p("/home/app/who")) as f:
            u, g = os.geteuid(), os.getegid()
            self.assertEqual(f.read(), f"{(u, u, u)} {(g, g, g)}")

    def test_child_death_is_a_refusal(self):
        def die(dir_fd, name):
            os._exit(3)

        dfd = mh.open_root(self.p("/home/app"))
        with self.assertRaises(mh.Refuse):
            mh.in_child(os.geteuid(), os.getegid(), dfd, die, "x")
        os.close(dfd)


if __name__ == "__main__":
    unittest.main()
