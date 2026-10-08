"""Unprivileged tests for lib/broker/broker.py: how sandbox-supplied text is
shown in dialogs, the one-dialog-per-sandbox queue, and the PulseAudio filter's
record classification and per-stream checks (against a fake server).
Run: python3 -m unittest lib/broker/tests/test_broker.py"""

import importlib.util
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("broker", os.path.join(HERE, "..", "broker.py"))
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)
broker.log = lambda msg: None


class Escape(unittest.TestCase):
    def test_controls_and_invisibles(self):
        cases = {
            "a\nb": "a\\nb",
            "a\rb\tc": "a\\rb\\tc",
            "\x1b[2J": "\\x1b[2J",
            "\x85": "\\x85",  # C1 next line
            "x\u202ey": "x\\u202ey",  # right-to-left override
            "x\u2066y\u2069": "x\\u2066y\\u2069",  # isolates
            "a\u200bb": "a\\u200bb",  # zero-width space
            "a\u00a0b": "a\\xa0b",  # no-break space
            "a\u2028b": "a\\u2028b",  # line separator
            "a\u3164b": "a\\u3164b",  # Hangul filler (renders blank)
            "a\ufe0fb": "a\\ufe0fb",  # variation selector
            "\U000e0041": "\\U000e0041",  # tag character
            "\ud800": "\\ud800",  # lone surrogate (from JSON)
            "back\\slash": "back\\\\slash",
            "plain text, ünïcödé ok": "plain text, ünïcödé ok",
        }
        for raw, shown in cases.items():
            self.assertEqual(broker.escape(raw), shown, repr(raw))

    def test_stacked_marks(self):
        out = broker.escape("e" + "\u0301" * 6)
        self.assertEqual(out, "e" + "\u0301" * 3 + "\\u0301" * 3)

    def test_ascii_only(self):
        self.assertEqual(broker.escape("/usr/bin/l\u0455", ascii_only=True), "/usr/bin/l\\u0455")

    def test_backslash_kept(self):
        self.assertEqual(broker.escape("a\\n\nb", backslash=False), "a\\n\\nb")


class Blocks(unittest.TestCase):
    def test_lines_and_cap(self):
        out = broker.block("x" * 1000, max_lines=3, width=80).split("\n")
        self.assertEqual(len(out), 4)
        for line in out[:3]:
            self.assertTrue(line.startswith(broker.GUTTER))
            self.assertEqual(len(line), len(broker.GUTTER) + 80)
        self.assertEqual(out[3], "… (760 more characters not shown)")

    def test_short_and_empty(self):
        self.assertEqual(broker.block("abc"), broker.GUTTER + "abc")
        self.assertEqual(broker.block(""), broker.GUTTER)

    def test_argv(self):
        self.assertEqual(broker.show_argv(["ls", "-l", "a b"]), "ls -l 'a b'")
        self.assertEqual(broker.show_argv(["sh", "-c", "true\nrm -rf ~"]), "sh -c 'true\\nrm -rf ~'")
        self.assertEqual(broker.show_argv(["\u0441at", "\u0441at"]), "'\\u0441at' 'сat'")
        self.assertEqual(broker.show_argv(["x", ""]), "x ''")

    def test_scrub(self):
        out = broker.scrub("ok\nbad\u202eline\n" + "y" * 200)
        self.assertEqual(out.split("\n")[1], "bad\\u202eline")
        self.assertTrue(out.split("\n")[2].endswith("(40 more characters not shown)"))


def make_broker(tmp, prompt_answer="deny", sandboxes=None):
    log = os.path.join(tmp, "prompts.jsonl")
    prompt = os.path.join(tmp, "prompt")
    with open(prompt, "w") as f:
        f.write(
            f"#!{sys.executable}\n"
            "import json, sys\n"
            f"open({log!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"print({prompt_answer!r})\n"
        )
    os.chmod(prompt, 0o755)
    cfg = {
        "prompt": prompt,
        "run0": "/bin/false",
        "systemctl": "/bin/false",
        "sandboxes": sandboxes or {"sb": {"label": "Test sandbox", "grantPaths": "/bin/true"}},
    }
    return broker.Broker(cfg), log


def dialogs(log):
    with open(log) as f:
        return [json.loads(line) for line in f]


class Dialogs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def check_dialog(self, args):
        """Every line holding sandbox text (FAKE) sits behind the gutter, and
        no line is long enough to push the rest off screen."""
        label, summary, detail = args[args.index("--") + 1 :]
        self.assertEqual(label, "Test sandbox")
        for text in (summary, detail):
            for line in text.split("\n"):
                self.assertLessEqual(len(line), 2 * broker.FIELD_WIDTH)
                if "FAKE" in line:
                    self.assertTrue(line.startswith(broker.GUTTER), repr(line))
        self.assertNotIn("FAKE", summary)

    def test_exec_spoof(self):
        b, log = make_broker(self.tmp.name)
        sent = []
        evil = "FAKE\n\nTest sandbox asks to:\n  FAKE read a file\u202e" + " " * 300 + "FAKE"
        b.op_exec("sb", {"argv": ["rm", "-rf", evil], "reason": evil * 3, "as": "root"}, sent.append)
        self.assertEqual(sent, [{"type": "denied", "reason": "denied by the user"}])
        (args,) = dialogs(log)
        self.assertIn("--no-session", args)
        self.check_dialog(args)
        detail = args[-1]
        self.assertIn("more characters not shown", detail)
        self.assertIn(broker.UNTRUSTED_NOTE, detail)
        self.assertEqual(args[-2], "run a command outside its sandbox as ROOT")

    def test_grant_path_spoof(self):
        home = os.path.join(self.tmp.name, "home")
        d = os.path.join(home, "FAKE\u202e\u200bdir\tx")
        os.makedirs(d)
        old = os.environ.get("HOME")
        os.environ["HOME"] = home
        try:
            b, log = make_broker(self.tmp.name)
            sent = []
            b.op_grant_path("sb", {"path": d, "write": True, "reason": "FAKE\nFAKE"}, sent.append)
        finally:
            if old is not None:
                os.environ["HOME"] = old
        self.assertEqual(sent[-1]["type"], "denied")
        (args,) = dialogs(log)
        self.check_dialog(args)
        self.assertIn("FAKE\\u202e\\u200bdir\\tx", args[-1])


class Queue(unittest.TestCase):
    def test_one_dialog_per_sandbox(self):
        with tempfile.TemporaryDirectory() as tmp:
            b, _ = make_broker(tmp, sandboxes={"sb": {"label": "a"}, "other": {"label": "b"}})
        on_screen = {"sb": 0, "other": 0}
        most = {"sb": 0, "other": 0}
        lock = threading.Lock()
        release = threading.Event()

        def ask(sandbox, key, summary, detail, allow_session):
            with lock:
                on_screen[sandbox] += 1
                most[sandbox] = max(most[sandbox], on_screen[sandbox])
            release.wait(5)
            time.sleep(0.01)
            with lock:
                on_screen[sandbox] -= 1
            return True, "allowed once"

        b.ask = ask
        results = []

        def go(sandbox, n):
            results.append((sandbox, b.decide(sandbox, "camera", ("k", n), "s", "d")))

        threads = [threading.Thread(target=go, args=("sb", i)) for i in range(broker.PROMPT_QUEUE + 3)]
        threads.append(threading.Thread(target=go, args=("other", 0)))
        for t in threads:
            t.start()
        time.sleep(0.3)
        release.set()
        for t in threads:
            t.join(10)
        self.assertEqual(most, {"sb": 1, "other": 1})
        sb = [r for s, r in results if s == "sb"]
        self.assertEqual(sum(ok for ok, _ in sb), broker.PROMPT_QUEUE + 1)
        self.assertEqual(sum(not ok and "waiting" in why for ok, why in sb), 2)
        self.assertEqual(b.waiting, {"sb": 0, "other": 0})

    def test_session_answer_covers_queued(self):
        with tempfile.TemporaryDirectory() as tmp:
            b, _ = make_broker(tmp)
        asked = []

        def ask(sandbox, key, summary, detail, allow_session):
            asked.append(key)
            time.sleep(0.2)
            b.approved[(sandbox, key)] = time.time() + 100
            return True, "allowed for the session"

        b.ask = ask
        out = []
        ts = [threading.Thread(target=lambda: out.append(b.decide("sb", "camera", ("mic",), "s", "d"))) for _ in range(3)]
        for t in ts:
            t.start()
        for t in ts:
            t.join(5)
        self.assertEqual(asked, [("mic",)])
        self.assertTrue(all(ok for ok, _ in out))


# ── PulseAudio ──
def L(v):
    return b"L" + struct.pack("!I", v)


def T(s):
    return b"N" if s is None else b"t" + s.encode() + b"\0"


def B(v):
    return b"1" if v else b"0"


def P(props):
    out = b"P"
    for k, v in props.items():
        v = v.encode() + b"\0"
        out += T(k) + L(len(v)) + b"x" + struct.pack("!I", len(v)) + v
    return out + b"N"


INVALID = 0xFFFFFFFF


def record_payload(version, index=INVALID, name=None, direct=INVALID, props=None, tag=7):
    """A CREATE_RECORD_STREAM as libpulse's create_stream builds it."""
    p = L(broker.PA_CREATE_RECORD_STREAM) + L(tag)
    if version < 13:
        p += T("rec")
    p += b"a" + bytes([3, 2]) + struct.pack("!I", 48000)  # s16le stereo
    p += b"m" + bytes([2, 1, 2])
    p += L(index) + T(name) + L(INVALID) + B(False) + L(INVALID)
    if version >= 12:
        p += B(False) * 7
    if version >= 13:
        p += B(False) + B(True) + P(props or {"media.name": "x"}) + L(direct)
    if version >= 14:
        p += B(False)
    if version >= 15:
        p += B(False) * 2
    return p


class Record(unittest.TestCase):
    def kind(self, version=35, routes=False, **kw):
        req = broker.pa_record_request(record_payload(version, **kw), version)
        return broker.pa_record_kind(req, routes)

    def test_default_is_mic(self):
        self.assertEqual(self.kind(), ("mic", None, True))
        self.assertEqual(self.kind(name="@DEFAULT_SOURCE@"), ("mic", None, True))
        self.assertEqual(self.kind(version=12), ("mic", None, True))

    def test_monitors(self):
        self.assertEqual(self.kind(name="alsa_output.pci.monitor")[0:2], ("monitor", "alsa_output.pci.monitor"))
        self.assertEqual(self.kind(name="@DEFAULT_MONITOR@")[0], "monitor")

    def test_by_index_or_stream(self):
        self.assertEqual(self.kind(index=3), ("monitor", "the source numbered 3", False))
        self.assertEqual(self.kind(name="42"), ("monitor", "the source numbered 42", False))
        self.assertEqual(self.kind(name=" 42abc")[0], "monitor")
        kind, _, named = self.kind(direct=12)
        self.assertEqual((kind, named), ("monitor", False))

    def test_named_device(self):
        self.assertEqual(self.kind(name="alsa_input.usb-mic"), ("device", "alsa_input.usb-mic", True))

    def test_routing_props(self):
        self.assertEqual(self.kind(props={"target.object": "alsa_output.x"})[0], "monitor")
        self.assertEqual(self.kind(props={"stream.capture.sink": "true"})[0], "monitor")
        self.assertEqual(self.kind(props={"node.target": "55"})[0], "monitor")
        self.assertEqual(self.kind(routes=True)[0], "monitor")
        self.assertEqual(self.kind(props={"application.name": "x", "media.role": "phone"})[0], "mic")

    def test_unparseable(self):
        payload = record_payload(35)[:60]  # cut inside the proplist
        self.assertIsNone(broker.pa_record_request(payload, 35))
        self.assertIsNone(broker.pa_record_request(record_payload(35), None))
        self.assertEqual(broker.pa_record_kind(None)[0], "monitor")


def pkt(payload):
    return broker.pa_packet(payload)


def read_pkt(sock):
    sock.settimeout(5)
    got = broker.pa_read_packet(sock)
    return got[1] if got else None


class FilterTest(unittest.TestCase):
    """A PulseFilter between a socketpair (the client) and a fake server."""

    def setUp(self):
        path = f"\0sbx-broker-test-{os.getpid()}-{id(self)}"  # abstract: no path length limit
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(1)
        self.client, theirs = socket.socketpair()
        self.answers = []

        class FakeBroker:
            sandboxes = {"sb": {"audio": "microphone", "label": "sb"}}

            def decide(fb, sandbox, op, key, summary, detail, allow_session=True, **kw):
                self.answers.append((key, summary, allow_session))
                return True, "allowed once"

        self.filter = broker.PulseFilter(FakeBroker(), "sb", theirs, path)
        self.server, _ = self.listener.accept()
        self.thread = threading.Thread(target=self.filter.run, daemon=True)
        self.thread.start()
        self.handshake()

    def tearDown(self):
        self.client.close()
        self.server.close()
        self.thread.join(5)
        self.listener.close()

    def handshake(self):
        self.client.sendall(pkt(L(broker.PA_AUTH) + L(0) + L(35 | 0x80000000) + b"x" + struct.pack("!I", 0)))
        self.assertEqual(broker.pa_u32(read_pkt(self.server), 10), 35)  # shm cleared
        self.server.sendall(pkt(L(broker.PA_REPLY) + L(0) + L(35 | 0x80000000)))
        self.assertEqual(broker.pa_u32(read_pkt(self.client), 10), 35)

    def playback(self, tag, channel, index):
        self.client.sendall(pkt(L(broker.PA_CREATE_PLAYBACK_STREAM) + L(tag) + b"..."))
        read_pkt(self.server)
        self.server.sendall(pkt(L(broker.PA_REPLY) + L(tag) + L(channel) + L(index) + L(0)))
        read_pkt(self.client)

    def command(self, cmd, tag, rest):
        """Send a command; the payload the server got, or None when the filter
        answered the client with an error itself."""
        self.client.sendall(pkt(L(cmd) + L(tag) + rest))
        # A marker after it: whatever reaches the server first was the command.
        self.client.sendall(pkt(L(13) + L(999)))  # STAT
        got = read_pkt(self.server)
        if broker.pa_command(got)[1] == 999:
            err = read_pkt(self.client)
            self.assertEqual(broker.pa_command(err), (broker.PA_ERROR, tag))
            return None
        self.assertEqual(broker.pa_command(read_pkt(self.server))[1], 999)
        return got

    def test_volume_on_own_streams_only(self):
        self.playback(1, channel=0, index=40)
        vol = b"v" + bytes([1]) + struct.pack("!I", 0x10000)
        self.assertIsNotNone(self.command(37, 2, L(40) + vol))  # own sink input
        self.assertIsNone(self.command(37, 3, L(41) + vol))  # someone else's
        self.assertIsNone(self.command(69, 4, L(41) + B(True)))
        self.assertIsNone(self.command(98, 5, L(40) + vol))  # not a source output
        self.assertIsNone(self.command(99, 6, L(7) + B(True)))
        self.assertIsNone(self.command(49, 7, L(41)))
        self.assertIsNotNone(self.command(69, 8, L(40) + B(True)))
        # Deleted: the index may belong to another client next.
        self.assertIsNotNone(self.command(broker.PA_DELETE_PLAYBACK_STREAM, 9, L(0)))
        self.assertIsNone(self.command(37, 10, L(40) + vol))

    def test_killed_stream_forgotten(self):
        self.playback(1, channel=3, index=50)
        self.server.sendall(pkt(L(broker.PA_PLAYBACK_STREAM_KILLED) + L(INVALID) + L(3)))
        read_pkt(self.client)
        self.assertIsNone(self.command(69, 2, L(50) + B(True)))

    def test_refused(self):
        self.assertIsNone(self.command(36, 2, L(0) + T(None)))  # SET_SINK_VOLUME
        self.assertIsNone(self.command(68, 3, L(1) + L(2) + T(None)))  # MOVE_SOURCE_OUTPUT
        self.assertIsNone(self.command(19, 4, T("bell")))  # REMOVE_SAMPLE

    def test_record_classified(self):
        self.client.sendall(pkt(record_payload(35, direct=5, tag=11)))
        self.assertEqual(broker.pa_command(read_pkt(self.server)), (broker.PA_CREATE_RECORD_STREAM, 11))
        ((key, summary, allow_session),) = self.answers
        self.assertEqual(key[:2], ("microphone", "monitor"))
        self.assertEqual(summary, "record the sound other apps play")
        self.assertFalse(allow_session)
        # The approved stream is the client's own afterwards.
        self.server.sendall(pkt(L(broker.PA_REPLY) + L(11) + L(0) + L(70)))
        read_pkt(self.client)
        self.assertIsNotNone(self.command(98, 12, L(70) + b"v" + bytes([1]) + struct.pack("!I", 0)))

    def test_client_proplist_routes(self):
        self.assertIsNotNone(self.command(broker.PA_SET_CLIENT_NAME, 1, P({"target.object": "x"})))
        self.client.sendall(pkt(record_payload(35, tag=2)))
        read_pkt(self.server)
        self.assertEqual(self.answers[0][0][1], "monitor")

    def test_record_proplist_update(self):
        self.assertIsNone(self.command(80, 1, L(0) + L(1) + P({"target.object": "x"})))
        self.assertIsNotNone(self.command(80, 2, L(0) + L(1) + P({"media.name": "x"})))


if __name__ == "__main__":
    unittest.main()
