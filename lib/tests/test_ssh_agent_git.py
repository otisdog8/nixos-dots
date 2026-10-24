"""ssh-agent-git's filter: what it lets through to the agent.

    python3 -m unittest discover -s lib/tests
"""

import importlib.util
import os
import pwd
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import unittest

PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ssh-agent-git.py")
spec = importlib.util.spec_from_file_location("ssh_agent_git", PATH)
sag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sag)


def s(b):
    return struct.pack(">I", len(b)) + b


def sign_request(data, key=b"key", flags=0):
    return bytes([sag.SIGN_REQUEST]) + s(key) + s(data) + struct.pack(">I", flags)


def userauth(user, service=b"ssh-connection", method=b"publickey"):
    return (
        s(b"\x11" * 32)
        + bytes([sag.USERAUTH_REQUEST])
        + s(user)
        + s(service)
        + s(method)
        + b"\x01"
        + s(b"ssh-ed25519")
        + s(b"blob")
    )


def sshsig(namespace):
    return sag.SSHSIG_MAGIC + s(namespace) + s(b"") + s(b"sha512") + s(b"h" * 64)


class Allowed(unittest.TestCase):
    def test_identities(self):
        self.assertTrue(sag.allowed(bytes([sag.REQUEST_IDENTITIES])))
        self.assertFalse(sag.allowed(bytes([sag.REQUEST_IDENTITIES, 0])))

    def test_git_login(self):
        self.assertTrue(sag.allowed(sign_request(userauth(b"git"))))
        self.assertTrue(
            sag.allowed(sign_request(userauth(b"git", method=b"publickey-hostbound-v00@openssh.com")))
        )

    def test_other_logins(self):
        for user in (b"jrt", b"root", b"gitx", b""):
            self.assertFalse(sag.allowed(sign_request(userauth(user))), user)
        self.assertFalse(sag.allowed(sign_request(userauth(b"git", service=b"other"))))

    def test_sshsig(self):
        self.assertTrue(sag.allowed(sign_request(sshsig(b"git"))))
        self.assertFalse(sag.allowed(sign_request(sshsig(b"file"))))

    def test_malformed(self):
        self.assertFalse(sag.allowed(sign_request(b"")))
        self.assertFalse(sag.allowed(sign_request(b"\x00\x00\xff\xff")))
        self.assertFalse(sag.allowed(sign_request(userauth(b"git"))[:-2]))
        self.assertFalse(sag.allowed(sign_request(userauth(b"git")) + b"x"))

    def test_other_requests(self):
        # add identity, remove all, lock, extension (session-bind)
        for kind in (17, 19, 22, 27):
            self.assertFalse(sag.allowed(bytes([kind]) + s(b"x")), kind)


def have_openssh():
    try:
        pwd.getpwuid(os.getuid())  # ssh-keygen refuses to run without a passwd entry
    except KeyError:
        return False
    return bool(shutil.which("ssh-agent") and shutil.which("ssh-keygen"))


@unittest.skipUnless(have_openssh(), "no usable openssh")
class AgainstRealAgent(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
        self.addCleanup(shutil.rmtree, self.dir)
        self.agent_sock = os.path.join(self.dir, "agent")
        self.agent = subprocess.Popen(["ssh-agent", "-D", "-a", self.agent_sock], stdout=subprocess.DEVNULL)
        self.addCleanup(self.agent.kill)
        key = os.path.join(self.dir, "id")
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key], check=True)
        for _ in range(100):
            if os.path.exists(self.agent_sock):
                break
            threading.Event().wait(0.05)
        env = dict(os.environ, SSH_AUTH_SOCK=self.agent_sock)
        subprocess.run(["ssh-add", "-q", key], env=env, check=True, stderr=subprocess.DEVNULL)
        self.pub = key + ".pub"
        os.unlink(key)  # only the agent can sign now
        self.filter_sock = os.path.join(self.dir, "filter")
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(self.filter_sock)
        listener.listen()
        self.addCleanup(listener.close)
        threading.Thread(target=self.serve, args=(listener,), daemon=True).start()

    def serve(self, listener):
        while True:
            try:
                conn, _ = listener.accept()
            except OSError:
                return
            subprocess.Popen(["python3", "-IS", PATH, self.agent_sock], stdin=conn)
            conn.close()

    def sign(self, namespace):
        msg = os.path.join(self.dir, "msg")
        with open(msg, "w") as f:
            f.write("hello\n")
        env = dict(os.environ, SSH_AUTH_SOCK=self.filter_sock)
        return subprocess.run(
            ["ssh-keygen", "-Y", "sign", "-n", namespace, "-f", self.pub, msg],
            env=env,
            capture_output=True,
        ).returncode

    def test_git_signature(self):
        self.assertEqual(self.sign("git"), 0)

    def test_other_namespace(self):
        self.assertNotEqual(self.sign("file"), 0)

    def test_cannot_add_or_remove(self):
        env = dict(os.environ, SSH_AUTH_SOCK=self.filter_sock)
        self.assertNotEqual(subprocess.run(["ssh-add", "-D"], env=env, capture_output=True).returncode, 0)
        listed = subprocess.run(["ssh-add", "-l"], env=env, capture_output=True)
        self.assertEqual(listed.returncode, 0)


if __name__ == "__main__":
    unittest.main()
