"""Tests for sbx-polkit-agent (lib/vm/polkit-agent.py) against a private
dbus-daemon, a fake polkitd (just the Authority methods the agent uses, and the
calls polkitd makes on agents) and a fake host broker.

  DBUS_DAEMON=$(command -v dbus-daemon) python3 -m unittest discover -s lib/vm/tests

Covers the wire formats (subject, identity, AuthenticationAgentResponse2),
which process gets an agent, one connection per registration, granted /
denied / unhandled / cancelled authentications, and dropping the registration
when the process exits. Not covered: real polkitd semantics (see
docs/op-broker.md's hardware checklist).
"""

import importlib.util
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("polkit_agent", os.path.join(HERE, "..", "polkit-agent.py"))
pa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pa)

from jeepney import (  # noqa: E402
    DBusAddress,
    HeaderFields,
    MatchRule,
    MessageType,
    new_error,
    new_method_call,
    new_method_return,
)
from jeepney.bus_messages import message_bus  # noqa: E402
from jeepney.io.threading import DBusRouter, Proxy, open_dbus_connection  # noqa: E402

UNLOCK = "com.1password.1Password.unlock"
CLI = "com.1password.1Password.authorizeCLI"


class Bus:
    """A private bus that allows everything, as the "system" bus."""

    def __init__(self, tmp):
        daemon = os.environ.get("DBUS_DAEMON") or shutil.which("dbus-daemon")
        if not daemon:
            raise unittest.SkipTest("no dbus-daemon")
        self.path = os.path.join(tmp, "bus")
        conf = os.path.join(tmp, "bus.conf")
        with open(conf, "w") as f:
            f.write(
                f"""<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <listen>unix:path={self.path}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
"""
            )
        self.proc = subprocess.Popen([daemon, "--config-file", conf, "--nofork", "--nopidfile"])
        for _ in range(100):
            if os.path.exists(self.path):
                break
            time.sleep(0.05)
        os.environ["DBUS_SYSTEM_BUS_ADDRESS"] = f"unix:path={self.path}"

    def close(self):
        self.proc.terminate()
        self.proc.wait(5)


class FakePolkit:
    """org.freedesktop.PolicyKit1 on the private bus: records registrations
    and responses, and can start an authentication on a registered agent."""

    ADDR = "/org/freedesktop/PolicyKit1/Authority"

    def __init__(self):
        self.conn = open_dbus_connection(bus="SYSTEM")
        self.router = DBusRouter(self.conn)
        Proxy(message_bus, self.router, timeout=5).RequestName("org.freedesktop.PolicyKit1", 0)
        self.agents = {}  # subject pid -> (unique name, path, subject)
        self.responses = queue.Queue()
        self.q = queue.Queue()
        self.router.filter(MatchRule(type="method_call", path=self.ADDR), queue=self.q)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            msg = self.q.get()
            member = msg.header.fields.get(HeaderFields.member)
            sender = msg.header.fields.get(HeaderFields.sender)
            sig = msg.header.fields.get(HeaderFields.signature)
            if member == "RegisterAuthenticationAgent":
                assert sig == "(sa{sv})ss", sig
                subject, locale, path = msg.body
                kind, details = subject
                assert kind == "unix-process"
                assert details["pid"][0] == "u" and details["start-time"][0] == "t" and details["uid"][0] == "i"
                self.agents[details["pid"][1]] = (sender, path, subject)
                self.router.send(new_method_return(msg))
            elif member == "AuthenticationAgentResponse2":
                assert sig == "us(sa{sv})", sig
                self.responses.put(msg.body)
                self.router.send(new_method_return(msg))
            else:
                self.router.send(new_error(msg, "org.freedesktop.DBus.Error.UnknownMethod", "s", ("?",)))

    def begin(self, pid, action, cookie, uid, timeout=10):
        """BeginAuthentication on pid's agent, as polkitd would; returns the reply."""
        name, path, _ = self.agents[pid]
        addr = DBusAddress(path, bus_name=name, interface="org.freedesktop.PolicyKit1.AuthenticationAgent")
        identities = [("unix-user", {"uid": ("u", uid)}), ("unix-group", {"gid": ("u", 1)})]
        msg = new_method_call(
            addr,
            "BeginAuthentication",
            "sssa{ss}sa(sa{sv})",
            (action, "msg", "icon", {"polkit.subject-pid": str(pid)}, cookie, identities),
        )
        return self.router.send_and_get_reply(msg, timeout=timeout)

    def cancel(self, pid, cookie):
        name, path, _ = self.agents[pid]
        addr = DBusAddress(path, bus_name=name, interface="org.freedesktop.PolicyKit1.AuthenticationAgent")
        return self.router.send_and_get_reply(new_method_call(addr, "CancelAuthentication", "s", (cookie,)), timeout=5)

    def name_has_owner(self, name):
        return Proxy(message_bus, self.router, timeout=5).NameHasOwner(name)[0]


class FakeBroker:
    """The host broker's authenticate op: answers from `self.answer`."""

    def __init__(self, path):
        self.path = path
        self.answer = {"type": "granted"}
        self.delay = 0
        self.requests = []
        self.closed_early = threading.Event()
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(4)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            conn, _ = self.srv.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        buf = b""
        while b"\n" not in buf:
            c = conn.recv(4096)
            if not c:
                return
            buf += c
        self.requests.append(json.loads(buf.split(b"\n")[0]))
        deadline = time.monotonic() + self.delay
        conn.settimeout(0.1)
        while time.monotonic() < deadline:
            try:
                if conn.recv(1) == b"":
                    self.closed_early.set()
                    return
            except socket.timeout:
                pass
        try:
            conn.sendall(json.dumps(self.answer).encode() + b"\n")
        except OSError:
            pass
        conn.close()


class TestAgent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="polkit-agent-test-")
        cls.bus = Bus(cls.tmp)
        cls.polkit = FakePolkit()

    @classmethod
    def tearDownClass(cls):
        cls.bus.close()

    def setUp(self):
        self.broker = FakeBroker(os.path.join(tempfile.mkdtemp(dir=self.tmp), "broker.sock"))
        # The "app": a process of ours with a distinctive executable name (a
        # copy of sleep, run with argv[0] "sleep" in case it's multi-call).
        d = tempfile.mkdtemp(dir=self.tmp)
        self.target = f"fakeapp-{os.getpid()}-{id(self)}"
        self.exe = os.path.join(d, self.target)
        shutil.copy(os.path.realpath(shutil.which("sleep")), self.exe)
        self.app = subprocess.Popen(["sleep", "60"], executable=self.exe)
        self.other = subprocess.Popen(["sleep", "60"])
        self.uid = os.getuid()
        cfg = pa.Config(self.uid, [self.target], [UNLOCK, CLI], self.broker.path)
        self.watcher = pa.Watcher(cfg)

    def tearDown(self):
        for p in (self.app, self.other):
            p.kill()
            p.wait()
        for a in self.watcher.agents.values():
            a.close()

    def registered(self):
        self.watcher.step()
        deadline = time.monotonic() + 5
        while self.app.pid not in self.polkit.agents and time.monotonic() < deadline:
            time.sleep(0.05)
        return self.app.pid in self.polkit.agents

    def test_registers_for_matching_processes_only(self):
        self.assertTrue(self.registered())
        self.assertEqual({k[0] for k in self.watcher.agents}, {self.app.pid})
        self.assertNotIn(self.other.pid, self.polkit.agents)
        # A second matching process gets its own agent on its own connection.
        second = subprocess.Popen(["sleep", "60"], executable=self.exe)
        try:
            self.watcher.step()
            deadline = time.monotonic() + 5
            while second.pid not in self.polkit.agents and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertIn(second.pid, self.polkit.agents)
            self.assertNotEqual(self.polkit.agents[second.pid][0], self.polkit.agents[self.app.pid][0])
        finally:
            second.kill()
            second.wait()
        _, _, subject = self.polkit.agents[self.app.pid]
        start = pa.proc_info(self.app.pid)[1]
        self.assertEqual(subject[1]["start-time"][1], start)
        self.assertEqual(subject[1]["uid"][1], self.uid)

    def test_other_users_and_names_ignored(self):
        cfg = pa.Config(self.uid + 1, [self.target], [UNLOCK], self.broker.path)
        self.assertEqual(pa.scan(cfg.uid, cfg.names), set())
        self.assertEqual(pa.scan(self.uid, {"no-such-exe"}), set())

    def test_granted(self):
        self.assertTrue(self.registered())
        r = self.polkit.begin(self.app.pid, UNLOCK, "cookie-1", self.uid)
        self.assertEqual(r.header.message_type, MessageType.method_return)
        self.assertEqual(self.broker.requests, [{"op": "authenticate", "action": UNLOCK}])
        uid, cookie, identity = self.polkit.responses.get(timeout=5)
        self.assertEqual((uid, cookie), (0, "cookie-1"))
        self.assertEqual(identity, ("unix-user", {"uid": ("u", self.uid)}))

    def test_denied(self):
        self.broker.answer = {"type": "denied", "reason": "dismissed"}
        self.assertTrue(self.registered())
        r = self.polkit.begin(self.app.pid, CLI, "cookie-2", self.uid)
        self.assertEqual(r.header.message_type, MessageType.error)
        self.assertTrue(self.polkit.responses.empty())

    def test_unhandled_action_never_reaches_the_host(self):
        self.assertTrue(self.registered())
        r = self.polkit.begin(self.app.pid, "org.freedesktop.login1.reboot", "cookie-3", self.uid)
        self.assertEqual(r.header.message_type, MessageType.error)
        self.assertEqual(self.broker.requests, [])
        self.assertTrue(self.polkit.responses.empty())

    def test_wrong_identity_refused(self):
        self.assertTrue(self.registered())
        r = self.polkit.begin(self.app.pid, UNLOCK, "cookie-4", self.uid + 1)
        self.assertEqual(r.header.message_type, MessageType.error)
        self.assertEqual(self.broker.requests, [])

    def test_cancel(self):
        self.broker.delay = 10
        self.assertTrue(self.registered())
        out = {}
        t = threading.Thread(target=lambda: out.setdefault("r", self.polkit.begin(self.app.pid, UNLOCK, "c5", self.uid, 20)))
        t.start()
        deadline = time.monotonic() + 5
        while not self.broker.requests and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(self.polkit.cancel(self.app.pid, "c5").header.message_type, MessageType.method_return)
        t.join(10)
        self.assertEqual(out["r"].header.message_type, MessageType.error)
        self.assertEqual(out["r"].header.fields[HeaderFields.error_name], pa.ERR_CANCELLED)
        # The host broker saw the connection close (and so cancels the dialog).
        self.assertTrue(self.broker.closed_early.wait(5))
        self.assertTrue(self.polkit.responses.empty())

    def test_broker_unreachable(self):
        os.unlink(self.broker.path)
        self.assertTrue(self.registered())
        r = self.polkit.begin(self.app.pid, UNLOCK, "c6", self.uid)
        self.assertEqual(r.header.message_type, MessageType.error)

    def test_process_exit_drops_registration(self):
        self.assertTrue(self.registered())
        name = self.polkit.agents[self.app.pid][0]
        self.assertTrue(self.polkit.name_has_owner(name))
        self.app.kill()
        self.app.wait()
        self.watcher.step()
        self.assertNotIn(self.app.pid, {k[0] for k in self.watcher.agents})
        deadline = time.monotonic() + 5
        while self.polkit.name_has_owner(name) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(self.polkit.name_has_owner(name))


if __name__ == "__main__":
    unittest.main()
