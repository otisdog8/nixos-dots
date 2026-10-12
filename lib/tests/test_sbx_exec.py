"""sbx-exec's relay: an agent and clients on a local socket (no sandbox).

    python3 -m unittest discover -s lib/tests
"""

import fcntl
import json
import os
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

SBX_EXEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sbx-exec.py")
PY = [sys.executable, "-IS"]
# A socket path relative to the agent's and clients' directory (TMPDIR may be
# too long for AF_UNIX).
SOCK = "a.sock"


def read_until(fd, pattern, timeout=10.0):
    """What the pty master `fd` gives until `pattern` shows up (or EIO)."""
    out = b""
    deadline = time.monotonic() + timeout
    while pattern not in out:
        left = deadline - time.monotonic()
        if left <= 0:
            raise AssertionError(f"timed out waiting for {pattern!r}; got {out!r}")
        r, _, _ = select.select([fd], [], [], left)
        if not r:
            continue
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        out += data
    return out


class Relay(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.agent = subprocess.Popen(
            [*PY, SBX_EXEC, "agent", "--listen", SOCK],
            cwd=cls.dir,
            stdin=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 10
        while not os.path.exists(os.path.join(cls.dir, SOCK)):
            if time.monotonic() > deadline:
                raise RuntimeError("agent didn't start")
            time.sleep(0.05)

    @classmethod
    def tearDownClass(cls):
        cls.agent.kill()
        cls.agent.wait()
        shutil.rmtree(cls.dir, ignore_errors=True)

    def run_client(self, cmd, **kw):
        return subprocess.run(
            [*PY, SBX_EXEC, "run", "--socket", SOCK, "--home", "--", *cmd],
            cwd=self.dir,
            capture_output=True,
            timeout=30,
            **kw,
        )

    def spawn_tty(self, cmd, rows=33, cols=111):
        """The client on a fresh pty (as from a terminal); (pid, master fd)."""
        pid, master = os.forkpty()
        if pid == 0:
            try:
                os.chdir(self.dir)
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("4H", rows, cols, 0, 0))
                os.execv(sys.executable, [*PY, SBX_EXEC, "run", "--socket", SOCK, "--home", "--", *cmd])
            finally:
                os._exit(127)
        self.addCleanup(os.close, master)
        return pid, master

    def wait_status(self, pid, master):
        """The client's exit status, reading (and dropping) its output meanwhile
        so it can't block on a full pty."""
        deadline = time.monotonic() + 20
        while True:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                return os.waitstatus_to_exitcode(status)
            if time.monotonic() > deadline:
                os.kill(pid, signal.SIGKILL)
                raise AssertionError("client didn't exit")
            r, _, _ = select.select([master], [], [], 0.05)
            if r:
                try:
                    os.read(master, 4096)
                except OSError:
                    pass

    # ── Pipes ────────────────────────────────────────────────────────────────
    def test_pipes_round_trip(self):
        p = self.run_client(["sh", "-c", "cat; echo err >&2; exit 7"], input=b"hello\nworld\n")
        self.assertEqual(p.returncode, 7)
        self.assertEqual(p.stdout, b"hello\nworld\n")
        self.assertEqual(p.stderr, b"err\n")

    def test_pipes_large_both_ways(self):
        data = os.urandom(3 << 20)
        p = self.run_client(["cat"], input=data)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout, data)

    def test_command_ignoring_stdin(self):
        p = self.run_client(["true"], input=b"x" * (3 << 20))
        self.assertEqual(p.returncode, 0)

    def test_signal_exit(self):
        p = self.run_client(["sh", "-c", "kill -TERM $$"])
        self.assertEqual(p.returncode, 128 + signal.SIGTERM)

    def test_not_found(self):
        p = self.run_client(["no-such-command-here"])
        self.assertEqual(p.returncode, 126)
        self.assertIn(b"command not found", p.stderr)

    def test_no_caller_fds_in_pipe_mode(self):
        # The command's stdin is the agent's pipe, not the caller's.
        r, w = os.pipe()
        try:
            mine = os.fstat(r).st_ino
            p = self.run_client(["sh", "-c", "stat -L -c %i /proc/self/fd/0"], stdin=r)
        finally:
            os.close(r)
            os.close(w)
        self.assertEqual(p.returncode, 0)
        self.assertNotEqual(int(p.stdout), mine)

    def test_forwarded_term(self):
        c = subprocess.Popen(
            [*PY, SBX_EXEC, "run", "--socket", SOCK, "--home", "--", "sh", "-c", "echo up; exec sleep 30"],
            cwd=self.dir,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
        )
        self.assertEqual(c.stdout.readline(), b"up\n")
        c.send_signal(signal.SIGTERM)
        self.assertEqual(c.wait(timeout=10), 128 + signal.SIGTERM)
        c.stdout.close()

    def test_old_launcher_refused(self):
        with socket.socket(socket.AF_UNIX) as s:
            s.connect(os.path.join(self.dir, SOCK))
            s.sendall(json.dumps({"argv": ["true"]}).encode() + b"\n")
            reply = json.loads(s.makefile("rb").readline())
        self.assertIn("older", reply["error"])

    def test_probe(self):
        p = subprocess.run(
            [*PY, SBX_EXEC, "probe", "--socket", SOCK, "--dir", self.dir],
            cwd=self.dir,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(p.returncode, 0, p.stderr)

    # ── A terminal ───────────────────────────────────────────────────────────
    def test_tty_and_size(self):
        pid, master = self.spawn_tty(["sh", "-c", "test -t 0 && test -t 1 && echo IS-A-TTY; stty size"])
        out = read_until(master, b"33 111")
        self.assertIn(b"IS-A-TTY", out)
        self.assertEqual(self.wait_status(pid, master), 0)

    def test_not_the_callers_terminal(self):
        pid, master = self.spawn_tty([sys.executable, "-c", "import os; print('NAME', os.ttyname(0))"])
        out = read_until(master, b"\n", timeout=10)
        out += read_until(master, b"\n")
        self.assertEqual(self.wait_status(pid, master), 0)
        ours = os.ptsname(master)
        name = out.split(b"NAME ", 1)[1].split()[0].decode()
        self.assertTrue(name.startswith("/dev/pts/"), out)
        self.assertNotEqual(name, ours)

    def test_resize_and_ctrl_c(self):
        pid, master = self.spawn_tty(
            ["sh", "-c", 'trap "stty size" WINCH; echo ready; while :; do sleep 0.1; done'], rows=24, cols=80
        )
        read_until(master, b"ready")
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("4H", 40, 120, 0, 0))
        read_until(master, b"40 120")
        # Ctrl-C as a byte: the client's terminal is raw, the sandbox's pty
        # makes it SIGINT.
        os.write(master, b"\x03")
        self.assertEqual(self.wait_status(pid, master), 128 + signal.SIGINT)

    def test_terminal_restored(self):
        pid, master = self.spawn_tty(["sh", "-c", "echo hi"])
        read_until(master, b"hi")
        self.assertEqual(self.wait_status(pid, master), 0)
        # Linux reports the slave's settings through the master.
        self.assertTrue(termios.tcgetattr(master)[3] & termios.ECHO)

    def test_leftover_cannot_read_the_terminal(self):
        """A process the command leaves behind (its own session, ignoring HUP)
        keeps the sandbox's pty, which goes dead with the command: it never
        sees what the user types into their terminal afterwards."""
        result = os.path.join(self.dir, "leftover.json")
        leftover = (
            "import json, os, signal, sys, time\n"
            "if os.fork():\n"
            "    os._exit(0)\n"
            "os.setsid()\n"
            "signal.signal(signal.SIGHUP, signal.SIG_IGN)\n"
            "time.sleep(1.0)\n"
            "try:\n"
            "    got = repr(os.read(0, 100))\n"
            "except OSError as e:\n"
            "    got = 'errno %d' % e.errno\n"
            f"open({result!r}, 'w').write(json.dumps(got))\n"
        )
        pid, master = self.spawn_tty([sys.executable, "-c", leftover])
        self.assertEqual(self.wait_status(pid, master), 0)
        # The user types into their own terminal, now back with their shell.
        os.write(master, b"SECRET\n")
        deadline = time.monotonic() + 10
        while not os.path.exists(result):
            self.assertLess(time.monotonic(), deadline, "the leftover never reported")
            time.sleep(0.05)
        time.sleep(0.05)
        with open(result) as f:
            got = json.load(f)
        self.assertNotIn("SECRET", got)
        self.assertIn(got, ("b''", "errno 5"))


if __name__ == "__main__":
    unittest.main()
