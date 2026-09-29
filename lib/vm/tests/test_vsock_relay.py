"""D-Bus auth regression tests; no KVM, vsock, or third-party Python needed."""

import importlib.util
from pathlib import Path
import queue
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location(
    "relay", Path(__file__).resolve().parents[1] / "vsock-relay.py"
)
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


class Stream:
    """In-memory duplex byte stream for environments forbidding socket I/O."""

    def __init__(self):
        self.incoming = queue.Queue()
        self.pending = b""
        self.closed = False

    def settimeout(self, timeout):
        pass

    def sendall(self, data):
        self.peer.incoming.put(data)

    def recv(self, size):
        if not self.pending:
            self.pending = self.incoming.get(timeout=2)
        result, self.pending = self.pending[:size], self.pending[size:]
        return result

    def shutdown(self, how):
        self.peer.incoming.put(b"")

    def close(self):
        if not self.closed:
            self.closed = True
            self.shutdown(socket.SHUT_WR)


def stream_pair():
    first, second = Stream(), Stream()
    first.peer, second.peer = second, first
    return first, second


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.client, front = stream_pair()
        back, self.server = stream_pair()
        self.errors = queue.Queue()
        for sock in (self.client, front, back, self.server):
            sock.settimeout(2)
            self.addCleanup(sock.close)

        def bridge():
            try:
                relay.dbus_auth(front, back)
                relay.splice(front, back)
            except Exception as exc:
                self.errors.put(exc)
            finally:
                front.close()
                back.close()

        self.thread = threading.Thread(target=bridge, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.client.close()
        self.server.close()
        self.thread.join(3)
        self.assertFalse(self.thread.is_alive())

    def exchange(self, command, reply):
        self.client.sendall(command)
        self.assertEqual(relay.read_auth_line(self.server), command)
        self.server.sendall(reply)
        self.assertEqual(relay.read_auth_line(self.client), reply)

    def authenticate(self):
        self.client.sendall(b"\0")
        self.assertEqual(self.server.recv(1), b"\0")
        self.exchange(b"AUTH EXTERNAL 31303031\r\n", b"OK abcdef\r\n")

    def test_fd_rejected_and_binary_stream_preserved(self):
        self.authenticate()
        # Fragmented negotiation must not reach the upstream bus at all.
        for part in (b"NEGOTIATE_", b"UNIX_FD\r", b"\n"):
            self.client.sendall(part)
        self.assertTrue(relay.read_auth_line(self.client).startswith(b"ERROR "))
        payload = b"\0\xffNEGOTIATE_UNIX_FD\r\n"
        self.client.sendall(b"BEGIN\r\n" + payload)
        self.assertEqual(relay.read_auth_line(self.server), b"BEGIN\r\n")
        received = b""
        while len(received) < len(payload):
            received += self.server.recv(len(payload) - len(received))
        self.assertEqual(received, payload)
        self.server.sendall(b"binary reply")
        self.assertEqual(self.client.recv(64), b"binary reply")
        self.assertTrue(self.errors.empty())

    def test_auth_retry_data_and_no_negotiation(self):
        self.client.sendall(b"\0")
        self.assertEqual(self.server.recv(1), b"\0")
        self.exchange(b"AUTH\r\n", b"REJECTED EXTERNAL\r\n")
        self.exchange(b"AUTH EXTERNAL\r\n", b"DATA\r\n")
        self.exchange(b"DATA 31303031\r\n", b"OK abcdef\r\n")
        self.client.sendall(b"BEGIN\r\n")
        self.assertEqual(relay.read_auth_line(self.server), b"BEGIN\r\n")
        self.assertTrue(self.errors.empty())

    def test_pipelined_client(self):
        # sd-bus sends its whole handshake and first message in one write.
        hello = b"l\x01\x00\x01hello-message"
        self.client.sendall(b"\0AUTH EXTERNAL 31303031\r\nNEGOTIATE_UNIX_FD\r\nBEGIN\r\n" + hello)
        self.assertEqual(self.server.recv(1), b"\0")
        self.assertEqual(relay.read_auth_line(self.server), b"AUTH EXTERNAL 31303031\r\n")
        self.server.sendall(b"OK abcdef\r\n")
        self.assertEqual(relay.read_auth_line(self.client), b"OK abcdef\r\n")
        self.assertTrue(relay.read_auth_line(self.client).startswith(b"ERROR "))
        self.assertEqual(relay.read_auth_line(self.server), b"BEGIN\r\n")
        received = b""
        while len(received) < len(hello):
            received += self.server.recv(len(hello) - len(received))
        self.assertEqual(received, hello)
        self.assertTrue(self.errors.empty())

    def test_fd_negotiation_with_tab_rejected_locally(self):
        # libdbus also splits commands on a tab; it must not reach the bus.
        self.authenticate()
        self.client.sendall(b"NEGOTIATE_UNIX_FD\tx\r\n")
        self.assertTrue(relay.read_auth_line(self.client).startswith(b"ERROR "))
        self.client.sendall(b"BEGIN\r\n")
        self.assertEqual(relay.read_auth_line(self.server), b"BEGIN\r\n")
        self.assertTrue(self.errors.empty())

    def test_cancel_resets_authentication(self):
        self.authenticate()
        self.exchange(b"CANCEL\r\n", b"REJECTED EXTERNAL\r\n")
        self.client.sendall(b"BEGIN\r\n")
        self.assertIsInstance(self.errors.get(timeout=2), ValueError)

    def test_begin_before_auth_fails_closed(self):
        self.client.sendall(b"\0BEGIN\r\n")
        self.assertIsInstance(self.errors.get(timeout=2), ValueError)
        self.assertEqual(self.client.recv(1), b"")

    def test_oversized_auth_fails_closed(self):
        self.client.sendall(b"\0" + b"A" * relay.MAX_AUTH_LINE)
        self.assertIsInstance(self.errors.get(timeout=2), ValueError)

    def test_disconnect_during_auth(self):
        self.client.sendall(b"\0AUTH")
        self.client.shutdown(socket.SHUT_WR)
        self.assertIsInstance(self.errors.get(timeout=2), EOFError)


@unittest.skipUnless(shutil.which("dbus-daemon") and shutil.which("dbus-send"),
                     "requires dbus-daemon and dbus-send")
class RealBusTests(unittest.TestCase):
    def test_method_call_through_auth_bridge(self):
        with tempfile.TemporaryDirectory() as directory:
            bus_path = directory + "/bus"
            proxy_path = directory + "/proxy"
            config = Path(directory) / "bus.conf"
            config.write_text('''<busconfig>
              <type>session</type>
              <listen>unix:tmpdir=/tmp</listen>
              <auth>EXTERNAL</auth>
              <policy context="default">
                <allow send_destination="*"/>
                <allow receive_sender="*"/>
                <allow own="*"/>
              </policy>
            </busconfig>''')
            daemon = subprocess.Popen(
                ["dbus-daemon", "--config-file=" + str(config), "--nofork", "--print-address=1",
                 "--address=unix:path=" + bus_path], stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True,
            )
            try:
                address = daemon.stdout.readline()
                if not address:
                    _, error = daemon.communicate(timeout=5)
                    if "Operation not permitted" in error or "Permission denied" in error:
                        self.skipTest("environment forbids private D-Bus sockets: " + error.strip())
                    self.fail(error)
                self.assertTrue(address.startswith("unix:"))
                # A sandbox without a passwd entry for its uid can start the
                # daemon but not register clients; that says nothing of the relay.
                direct = subprocess.run(
                    ["dbus-send", "--bus=unix:path=" + bus_path, "--print-reply",
                     "--dest=org.freedesktop.DBus", "/org/freedesktop/DBus",
                     "org.freedesktop.DBus.ListNames"],
                    capture_output=True, text=True, timeout=10,
                )
                if direct.returncode != 0:
                    self.skipTest("private bus unusable here: " + direct.stderr.strip())
                with socket.socket(socket.AF_UNIX) as listener:
                    listener.bind(proxy_path)
                    listener.listen(1)
                    listener.settimeout(5)
                    errors = queue.Queue()

                    def bridge():
                        try:
                            front, _ = listener.accept()
                            with front, socket.socket(socket.AF_UNIX) as back:
                                front.settimeout(5)
                                back.settimeout(5)
                                back.connect(bus_path)
                                relay.dbus_auth(front, back)
                                relay.splice(front, back)
                        except Exception as exc:
                            errors.put(exc)

                    thread = threading.Thread(target=bridge, daemon=True)
                    thread.start()
                    result = subprocess.run(
                        ["dbus-send", "--bus=unix:path=" + proxy_path, "--print-reply",
                         "--dest=org.freedesktop.DBus", "/org/freedesktop/DBus",
                         "org.freedesktop.DBus.ListNames"],
                        capture_output=True, text=True, timeout=10,
                    )
                    thread.join(6)
                    self.assertFalse(thread.is_alive())
                    self.assertTrue(errors.empty())
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('org.freedesktop.DBus', result.stdout)
            finally:
                daemon.terminate()
                daemon.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
