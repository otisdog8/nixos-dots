"""Tests for op-broker: validation, matching, policy, and the socket paths
(serve, native host, bridge + uplink), against a fake `op` and fake dialogs.

  python3 -m unittest discover -s pkgs/op-broker/tests -v
"""

import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(HERE)
sys.path.insert(0, SRC)

import op_broker as ob  # noqa: E402

FAKE_OP = os.path.join(HERE, "fake_op.py")
FAKE_DIALOG = os.path.join(HERE, "fake_dialog.py")
FAKE_LAUNCHER = os.path.join(HERE, "fake_launcher.py")
NATIVE_HOST = os.path.join(SRC, "native_host.py")

A = "a" * 26  # github, personal
B = "b" * 26  # github, work
C = "c" * 26  # login.example.com
D = "d" * 26  # http intranet
E = "e" * 26  # no URL
V1 = "v" * 25 + "1"
V2 = "v" * 25 + "2"

SECRETS = ["hunter2-personal", "hunter2-work", "example-pw", "intranet-pw"]

DB = [
    {
        "id": A,
        "title": "GitHub",
        "category": "LOGIN",
        "vault": {"id": V1, "name": "Personal"},
        "additional_information": "jacob",
        "urls": [{"label": "website", "primary": True, "href": "github.com"}],
        "fields": [
            {"id": "username", "type": "STRING", "purpose": "USERNAME", "value": "jacob"},
            {"id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "value": "hunter2-personal"},
            {"id": "notesPlain", "type": "STRING", "purpose": "NOTES", "value": "secret notes"},
            {"id": "otp", "type": "OTP", "label": "one-time password", "value": "otpauth://x", "totp": "123456"},
        ],
    },
    {
        "id": B,
        "title": "GitHub ‮evil",
        "category": "LOGIN",
        "vault": {"id": V2, "name": "Work"},
        "additional_information": "jacob-work",
        "urls": [{"href": "https://github.com/login"}],
        "fields": [
            {"id": "username", "type": "STRING", "purpose": "USERNAME", "value": "jacob-work"},
            {"id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "value": "hunter2-work"},
            {"id": "otp", "type": "OTP", "value": "otpauth://y"},
        ],
        "_otp": "654321",
    },
    {
        "id": C,
        "title": "Example",
        "category": "LOGIN",
        "vault": {"id": V1, "name": "Personal"},
        "urls": [{"href": "https://login.example.com/"}],
        "fields": [
            {"id": "username", "purpose": "USERNAME", "value": "me@example.com"},
            {"id": "password", "purpose": "PASSWORD", "value": "example-pw"},
        ],
    },
    {
        "id": D,
        "title": "Intranet",
        "category": "LOGIN",
        "vault": {"id": V1, "name": "Personal"},
        "urls": [{"href": "http://intranet.test:8080"}],
        "fields": [{"id": "password", "purpose": "PASSWORD", "value": "intranet-pw"}],
    },
    {"id": E, "title": "No URL", "category": "LOGIN", "vault": {"id": V1, "name": "Personal"}},
]


def lines(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


class Env:
    """A temp dir with the fake op's DB and logs, and a broker config."""

    def __init__(self, **over):
        self.dir = tempfile.mkdtemp(prefix="op-broker-test-")
        self.db = os.path.join(self.dir, "db.json")
        with open(self.db, "w") as f:
            json.dump(DB, f)
        self.op_log = os.path.join(self.dir, "op.log")
        self.dialog_log = os.path.join(self.dir, "dialog.log")
        self.audit = os.path.join(self.dir, "audit.jsonl")
        os.environ["FAKE_DIALOG_LOG"] = self.dialog_log
        os.environ["FAKE_PROMPT_ANSWER"] = "once"
        os.environ["FAKE_CHOOSE_ANSWER"] = "0"
        os.environ["FAKE_NOTICE_ANSWER"] = "dismiss"
        ob.audit = ob.Audit(self.audit)
        sockdir = os.path.join(self.dir, "clients")
        os.makedirs(os.path.join(sockdir, "firefox"))
        os.makedirs(os.path.join(sockdir, "chromium"))
        self.cfg = {
            "clients": {
                "firefox": {
                    "label": "Firefox (test)",
                    "socket": os.path.join(sockdir, "firefox", "sock"),
                    "users": [os.getuid()],
                },
                "chromium": {
                    "label": "Chromium (test)",
                    "socket": os.path.join(sockdir, "chromium", "sock"),
                    "users": [os.getuid()],
                },
            },
            "op": {
                "path": FAKE_OP,
                "extraEnv": {"FAKE_OP_DB": self.db, "FAKE_OP_LOG": self.op_log},
            },
            "prompt": {
                "command": [sys.executable, FAKE_DIALOG, "prompt"],
                "chooser": [sys.executable, FAKE_DIALOG, "choose"],
                "notice": [sys.executable, FAKE_DIALOG, "notice"],
                "timeout": 5,
                "queueWait": 1,
            },
            "limits": {"burst": 50, "perMinute": 600, "listCacheTtl": 0},
            "probe": {"distinct": 4, "window": 120, "interval": 600, "block": 3600},
        }
        for k, v in over.items():
            if isinstance(v, dict):
                self.cfg.setdefault(k, {}).update(v)
            else:
                self.cfg[k] = v

    def broker(self):
        return ob.Broker(self.cfg)

    def prompts(self):
        return [l for l in lines(self.dialog_log) if l[0] == "prompt"]

    def choosers(self):
        return [l for l in lines(self.dialog_log) if l[0] == "choose"]

    def notices(self, want=None, wait=3.0):
        """The notices shown so far. They run in the background: with `want`,
        wait (bounded) until that many have been logged."""
        deadline = time.monotonic() + wait
        while True:
            got = [l for l in lines(self.dialog_log) if l[0] == "notice"]
            if want is None or len(got) >= want or time.monotonic() > deadline:
                return got
            time.sleep(0.05)


def fill(broker, who, origin, want=("username", "password"), top=None):
    req = {"v": 1, "op": "fill", "origin": origin, "want": list(want)}
    if top:
        req["top"] = top
    return broker.handle(who, ob.parse_request(json.dumps(req), broker.allow_http))


# ── Pure functions ───────────────────────────────────────────────────────────


class TestOrigin(unittest.TestCase):
    def test_valid(self):
        for s in [
            "https://github.com",
            "https://a.b.c:8443",
            "https://[::1]:8443",
            "https://127.0.0.1",
            "https://xn--bcher-kva.example",
            "https://localhost",
        ]:
            self.assertEqual(str(ob.parse_origin(s)), s)
        self.assertEqual(str(ob.parse_origin("http://intranet.test:8080", True)), "http://intranet.test:8080")

    def test_invalid(self):
        for s in [
            "https://GitHub.com",
            "https://github.com/",
            "https://github.com/login",
            "https://user@github.com",
            "https://github.com:443",
            "https://github.com:0443",
            "https://github.com:70000",
            "http://github.com",
            "ftp://github.com",
            "https://bücher.example",
            "https://-a.com",
            "https://a..com",
            "https://github.com.",
            "https://1.2.3.999",
            "https://github.com\n",
            "https://github.com ",
            "null",
            "",
            42,
            None,
            "https://" + "a" * 300,
            "https://" + ".".join(["a" * 63] * 5),
        ]:
            with self.assertRaises(ob.BadRequest, msg=repr(s)):
                ob.parse_origin(s)


class TestItemUrl(unittest.TestCase):
    def test_parse(self):
        cases = {
            "github.com": "https://github.com",
            "HTTPS://GitHub.COM/login?x=1": "https://github.com",
            "http://example.com:80/": "http://example.com",
            "https://example.com:8443/x": "https://example.com:8443",
            "https://bücher.example": "https://xn--bcher-kva.example",
            "https://[::1]:8443": "https://[::1]:8443",
            "  https://github.com.  ": "https://github.com",
        }
        for href, want in cases.items():
            self.assertEqual(str(ob.parse_item_url(href)), want, href)
        for href in [
            "",
            None,
            "ftp://x.com",
            "javascript:alert(1)",
            "android://abc@com.example",
            "https://exa mple.com",
            "https://x.com:99999",
            "https://",
        ]:
            self.assertIsNone(ob.parse_item_url(href), repr(href))

    def test_match(self):
        o = lambda s: ob.parse_origin(s, True)  # noqa: E731
        i = ob.parse_item_url
        yes = [
            ("https://github.com", "github.com", "exact"),
            ("https://gist.github.com", "github.com", "subdomain"),
            ("https://a.b.github.com", "https://github.com", "subdomain"),
            ("https://example.com", "http://example.com", "subdomain"),  # http item on https page
            ("https://example.com:8443", "https://example.com:8443", "exact"),
            ("https://localhost", "https://localhost", "exact"),
        ]
        no = [
            ("https://example.com", "https://login.example.com", "subdomain"),  # parent
            ("https://evil.example.com", "https://login.example.com", "subdomain"),  # sibling
            ("https://github.com.evil.com", "github.com", "subdomain"),
            ("https://evilgithub.com", "github.com", "subdomain"),
            ("https://gist.github.com", "github.com", "exact"),
            ("http://github.com", "https://github.com", "subdomain"),  # downgrade
            ("https://example.com:8443", "https://example.com", "subdomain"),
            ("https://example.com", "https://example.com:8443", "subdomain"),
            ("https://a.localhost", "https://localhost", "subdomain"),  # single label
            ("https://x.127.0.0.1", "https://127.0.0.1", "subdomain"),  # IP: exact only
        ]
        for origin, item, mode in yes:
            self.assertTrue(ob.url_matches(o(origin), i(item), mode), (origin, item, mode))
        for origin, item, mode in no:
            self.assertFalse(ob.url_matches(o(origin), i(item), mode), (origin, item, mode))


class TestRequest(unittest.TestCase):
    def test_good(self):
        r = ob.parse_request(
            b'{"v":1,"op":"fill","id":7,"origin":"https://a.com","top":"https://a.com","want":["password","username"]}'
        )
        self.assertEqual(r["id"], 7)
        self.assertIsNone(r["top"])  # same as origin
        self.assertEqual(r["want"], frozenset({"username", "password"}))
        self.assertEqual(ob.parse_request('{"v":1,"op":"hello"}')["op"], "hello")

    def test_bad(self):
        for raw in [
            "",
            "[]",
            "not json",
            '{"op":"fill"}',
            '{"v":2,"op":"hello"}',
            '{"v":1,"op":"list"}',
            '{"v":1,"op":"hello","requester":"firefox"}',
            '{"v":1,"op":"hello","id":true}',
            '{"v":1,"op":"hello","id":-1}',
            '{"v":1,"op":"fill","origin":"https://a.com","want":[]}',
            '{"v":1,"op":"fill","origin":"https://a.com","want":["password","password"]}',
            '{"v":1,"op":"fill","origin":"https://a.com","want":["notes"]}',
            '{"v":1,"op":"fill","origin":"https://a.com","want":"password"}',
            '{"v":1,"op":"fill","origin":"https://a.com","want":["password"],"item":"x"}',
            '{"v":1,"op":"fill","origin":"https://a.com/","want":["password"]}',
            '{"v":1,"op":"fill","origin":"https://a.com","top":"null","want":["password"]}',
        ]:
            with self.assertRaises(ob.BadRequest, msg=raw):
                ob.parse_request(raw)

    def test_clean(self):
        self.assertEqual(ob.clean("a‮b\nc\x00d"), "a?b c?d")
        self.assertEqual(len(ob.clean("x" * 500, 80)), 80)


# ── Policy, against the fake op ──────────────────────────────────────────────


class TestBroker(unittest.TestCase):
    def setUp(self):
        self.env = Env()
        self.b = self.env.broker()

    def test_single_match_once(self):
        r = fill(self.b, "firefox", "https://login.example.com")
        self.assertEqual(r, {"ok": True, "title": "Example", "username": "me@example.com", "password": "example-pw"})
        p = self.env.prompts()
        self.assertEqual(len(p), 1)
        argv = p[0][1:]
        self.assertIn("--timeout", argv)
        sep = argv.index("--")
        who, summary, detail = argv[sep + 1 :]
        self.assertEqual(who, "Firefox (test)")
        self.assertIn('"Example"', summary)
        self.assertIn("https://login.example.com", summary)
        self.assertIn("Fields: username, password", detail)
        self.assertIn("Vault: Personal", detail)
        # op ran exactly: one listing, one get for the approved item.
        self.assertEqual(
            lines(self.env.op_log),
            [
                ["item", "list", "--categories", "Login", "--format", "json"],
                ["item", "get", C, "--vault", V1, "--format", "json", "--reveal"],
            ],
        )

    def test_no_secret_leaves_in_dialogs_or_audit(self):
        os.environ["FAKE_CHOOSE_ANSWER"] = "1"
        fill(self.b, "firefox", "https://github.com", ("username", "password", "totp"))
        fill(self.b, "firefox", "https://login.example.com")
        with open(self.env.dialog_log) as f:
            dialogs = f.read()
        with open(self.env.audit) as f:
            audit = f.read()
        for s in SECRETS + ["123456", "654321", "secret notes"]:
            self.assertNotIn(s, dialogs)
            self.assertNotIn(s, audit)

    def test_deny_and_cooldown(self):
        os.environ["FAKE_PROMPT_ANSWER"] = "deny"
        for _ in range(3):
            self.assertEqual(fill(self.b, "firefox", "https://login.example.com")["error"], "denied")
        self.assertEqual(fill(self.b, "firefox", "https://login.example.com")["error"], "cooldown")
        self.assertEqual(len(self.env.prompts()), 3)
        # Another requester is unaffected.
        os.environ["FAKE_PROMPT_ANSWER"] = "once"
        self.assertTrue(fill(self.b, "chromium", "https://login.example.com")["ok"])
        # Nothing was fetched for a denied item.
        gets = [l for l in lines(self.env.op_log) if l[:2] == ["item", "get"]]
        self.assertEqual(len(gets), 1)

    def test_session_grant(self):
        self.b.sessions.idle = 0.3
        os.environ["FAKE_PROMPT_ANSWER"] = "session"
        self.b.sessions.opened("firefox")
        self.assertTrue(fill(self.b, "firefox", "https://login.example.com")["ok"])
        os.environ["FAKE_PROMPT_ANSWER"] = "deny"
        # Same item + origin + fields (or fewer): no dialog.
        self.assertTrue(fill(self.b, "firefox", "https://login.example.com")["ok"])
        self.assertTrue(fill(self.b, "firefox", "https://login.example.com", ("password",))["ok"])
        self.assertEqual(len(self.env.prompts()), 1)
        # Not for another requester, another origin, or more fields.
        self.assertEqual(fill(self.b, "chromium", "https://login.example.com")["error"], "denied")
        self.assertEqual(fill(self.b, "firefox", "https://a.login.example.com")["error"], "denied")
        self.assertEqual(len(self.env.prompts()), 3)
        # Still alive within the grace period after the last connection closes...
        self.b.sessions.closed("firefox")
        self.assertTrue(fill(self.b, "firefox", "https://login.example.com")["ok"])
        # ...and gone after it.
        time.sleep(0.4)
        self.assertEqual(fill(self.b, "firefox", "https://login.example.com")["error"], "denied")

    def test_session_max(self):
        self.b.sessions.max = 0.2
        os.environ["FAKE_PROMPT_ANSWER"] = "session"
        self.b.sessions.opened("firefox")
        fill(self.b, "firefox", "https://login.example.com")
        time.sleep(0.3)
        os.environ["FAKE_PROMPT_ANSWER"] = "deny"
        self.assertEqual(fill(self.b, "firefox", "https://login.example.com")["error"], "denied")

    def test_no_session_option(self):
        self.b.allow_session = False
        os.environ["FAKE_PROMPT_ANSWER"] = "session"
        self.b.sessions.opened("firefox")
        fill(self.b, "firefox", "https://login.example.com")
        self.assertIn("--no-session", self.env.prompts()[0])
        fill(self.b, "firefox", "https://login.example.com")
        self.assertEqual(len(self.env.prompts()), 2)

    def test_multiple_candidates(self):
        os.environ["FAKE_CHOOSE_ANSWER"] = "1"
        r = fill(self.b, "firefox", "https://github.com", ("username", "password", "totp"))
        self.assertEqual(r["username"], "jacob-work")
        self.assertEqual(r["totp"], "654321")  # via --otp: the JSON had no code
        ch = self.env.choosers()
        self.assertEqual(len(ch), 1)
        opts = ch[0][ch[0].index("--") + 3 :]
        # Sorted by title; the bidi override is neutralized.
        self.assertEqual(opts, ["GitHub (jacob)", "GitHub ?evil (jacob-work)"])
        self.assertEqual(len(self.env.prompts()), 1)
        self.assertIn("--otp", lines(self.env.op_log)[-1])

    def test_chooser_cancel_is_denial(self):
        os.environ["FAKE_CHOOSE_ANSWER"] = ""
        self.assertEqual(fill(self.b, "firefox", "https://github.com")["error"], "denied")
        self.assertEqual(self.env.prompts(), [])
        self.assertFalse([l for l in lines(self.env.op_log) if l[:2] == ["item", "get"]])

    def test_chooser_out_of_range(self):
        os.environ["FAKE_CHOOSE_ANSWER"] = "7"
        self.assertEqual(fill(self.b, "firefox", "https://github.com")["error"], "denied")

    def test_totp_only(self):
        os.environ["FAKE_CHOOSE_ANSWER"] = "0"
        r = fill(self.b, "firefox", "https://github.com", ("totp",))
        self.assertEqual(r, {"ok": True, "title": "GitHub", "totp": "123456"})

    def test_no_match(self):
        for origin in ["https://evil.com", "https://example.com", "https://github.com.evil.com"]:
            self.assertEqual(fill(self.b, "firefox", origin)["error"], "no-match", origin)
        self.assertEqual(self.env.prompts(), [])
        self.assertEqual(self.env.choosers(), [])
        # Three sites is below the probing threshold.
        self.assertEqual(self.env.notices(wait=0.3), [])

    def test_subdomain_and_exact(self):
        self.assertTrue(fill(self.b, "firefox", "https://a.login.example.com")["ok"])
        env = Env(match={"mode": "exact"})
        self.assertEqual(fill(env.broker(), "firefox", "https://a.login.example.com")["error"], "no-match")

    def test_subdomain_match_is_called_out(self):
        # Exact host: no marker.
        fill(self.b, "firefox", "https://login.example.com")
        summary, detail = self.env.prompts()[0][-2:]
        self.assertNotIn("SUBDOMAIN", summary)
        self.assertNotIn("subdomain", detail)
        # Subdomain of the saved host: in the summary line, and explained.
        fill(self.b, "firefox", "https://a.login.example.com")
        summary, detail = self.env.prompts()[1][-2:]
        self.assertIn("on https://a.login.example.com", summary)
        self.assertIn("SUBDOMAIN MATCH: saved for login.example.com, not for a.login.example.com", summary)
        self.assertTrue(detail.startswith("This login is saved for https://login.example.com; the page is on a.login.example.com"))
        match = [l["match"] for l in lines(self.env.audit) if l["event"] == "fill" and "match" in l]
        self.assertEqual(match, ["exact", "subdomain"])

    def test_subdomain_in_chooser(self):
        env = Env()
        # A third GitHub login saved for gist.github.com itself: exact, so first.
        db = json.loads(open(env.db).read())
        db.append(
            {
                "id": "f" * 26,
                "title": "Gist",
                "category": "LOGIN",
                "vault": {"id": V1, "name": "Personal"},
                "urls": [{"href": "https://gist.github.com"}],
                "fields": [{"id": "password", "purpose": "PASSWORD", "value": "gist-pw"}],
            }
        )
        with open(env.db, "w") as f:
            json.dump(db, f)
        os.environ["FAKE_CHOOSE_ANSWER"] = "1"
        r = fill(env.broker(), "firefox", "https://gist.github.com")
        self.assertEqual(r["username"], "jacob")
        ch = env.choosers()[0]
        text = ch[ch.index("--") + 2]
        opts = ch[ch.index("--") + 3 :]
        self.assertIn("SUBDOMAIN", text)
        self.assertEqual(
            opts,
            [
                "Gist",
                "GitHub (jacob)  [SUBDOMAIN: saved for github.com, page is gist.github.com]",
                "GitHub ?evil (jacob-work)  [SUBDOMAIN: saved for github.com, page is gist.github.com]",
            ],
        )
        self.assertIn("SUBDOMAIN MATCH: saved for github.com, not for gist.github.com", env.prompts()[0][-2])

    # ── Probing notice ──

    def test_probe_notice(self):
        for i in range(3):
            self.assertEqual(fill(self.b, "firefox", f"https://site{i}.test")["error"], "no-match")
        # The same site again doesn't count twice.
        fill(self.b, "firefox", "https://site0.test")
        self.assertEqual(self.env.notices(wait=0.3), [])
        fill(self.b, "firefox", "https://site3.test")
        n = self.env.notices(want=1)
        self.assertEqual(len(n), 1)
        argv = n[0][1:]
        who, summary, detail = argv[argv.index("--") + 1 :]
        self.assertEqual(who, "Firefox (test)")
        self.assertIn("several sites", summary)
        for i in range(4):
            self.assertIn(f"https://site{i}.test", detail)
        # Rate-limited: more misses within the interval show nothing new.
        for i in range(4, 10):
            fill(self.b, "firefox", f"https://site{i}.test")
        self.assertEqual(len(self.env.notices(want=2, wait=0.5)), 1)
        # Per requester.
        for i in range(4):
            fill(self.b, "chromium", f"https://other{i}.test")
        self.assertEqual(len(self.env.notices(want=2)), 2)
        # Nothing was prompted or fetched, and the audit has the events.
        self.assertEqual(self.env.prompts(), [])
        ev = [l for l in lines(self.env.audit) if l["event"] == "probe-notice"]
        self.assertEqual([e["requester"] for e in ev], ["firefox", "chromium"])

    def test_probe_notice_after_interval(self):
        w = ob.ProbeWatch({"distinct": 2, "window": 100, "interval": 50})
        self.assertIsNone(w.miss("x", "https://a.test", now=0))
        self.assertEqual(w.miss("x", "https://b.test", now=1), ["https://a.test", "https://b.test"])
        self.assertIsNone(w.miss("x", "https://c.test", now=2))
        # Outside the window the old ones are forgotten.
        self.assertIsNone(w.miss("x", "https://d.test", now=200))
        self.assertEqual(w.miss("x", "https://e.test", now=201), ["https://d.test", "https://e.test"])

    def test_probe_block(self):
        os.environ["FAKE_NOTICE_ANSWER"] = "block"
        for i in range(4):
            fill(self.b, "firefox", f"https://site{i}.test")
        self.env.notices(want=1)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if fill(self.b, "firefox", "https://login.example.com").get("error") == "cooldown":
                break
            time.sleep(0.05)
        self.assertEqual(fill(self.b, "firefox", "https://login.example.com")["error"], "cooldown")
        self.assertTrue(fill(self.b, "chromium", "https://login.example.com")["ok"])
        self.assertTrue([l for l in lines(self.env.audit) if l["event"] == "probe-block"])

    def test_rate_limit_notice(self):
        env = Env(limits={"burst": 2, "perMinute": 0.0001})
        b = env.broker()
        codes = [fill(b, "firefox", f"https://s{i}.test").get("error") for i in range(4)]
        self.assertEqual(codes, ["no-match", "no-match", "rate-limited", "rate-limited"])
        n = env.notices(want=1)
        self.assertEqual(len(n), 1)
        summary, detail = n[0][-2:]
        self.assertIn("more login requests", summary)
        self.assertIn("https://s2.test", detail)
        self.assertEqual(len(env.notices(want=2, wait=0.3)), 1)

    def test_no_notice_command(self):
        env = Env()
        env.cfg["prompt"]["notice"] = []
        b = env.broker()
        for i in range(5):
            fill(b, "firefox", f"https://site{i}.test")
        self.assertEqual(env.notices(wait=0.3), [])
        self.assertTrue([l for l in lines(env.audit) if l["event"] == "probe-notice"])

    def test_http_needs_allow_http(self):
        with self.assertRaises(ob.BadRequest):
            fill(self.b, "firefox", "http://intranet.test:8080")
        env = Env(match={"allowHttp": True})
        r = fill(env.broker(), "firefox", "http://intranet.test:8080", ("password",))
        self.assertEqual(r["password"], "intranet-pw")

    def test_embedded_form_is_called_out(self):
        fill(self.b, "firefox", "https://login.example.com", top="https://news.test")
        detail = self.env.prompts()[0][-1]
        self.assertIn("embedded in a page from https://news.test", detail)

    def test_rate_limit(self):
        env = Env(limits={"burst": 3, "perMinute": 0.0001})
        b = env.broker()
        codes = [fill(b, "firefox", "https://evil.com").get("error") for _ in range(4)]
        self.assertEqual(codes, ["no-match", "no-match", "no-match", "rate-limited"])
        self.assertEqual(fill(b, "chromium", "https://evil.com")["error"], "no-match")

    def test_hourly_cap(self):
        lim = ob.Limiter({"burst": 100, "perMinute": 6000, "perHour": 2})
        self.assertIsNone(lim.take("x", 0))
        self.assertIsNone(lim.take("x", 1))
        self.assertEqual(lim.take("x", 2), "rate-limited")
        self.assertIsNone(lim.take("x", 3601))

    def test_busy(self):
        self.b.inflight.add("firefox")
        self.assertEqual(fill(self.b, "firefox", "https://login.example.com")["error"], "busy")

    def test_dialog_queue(self):
        self.b.dialog.acquire()
        try:
            self.assertEqual(fill(self.b, "firefox", "https://login.example.com")["error"], "busy")
        finally:
            self.b.dialog.release()

    def test_vault_restriction(self):
        env = Env(op={"vaults": [V2]})
        b = env.broker()
        self.assertEqual(fill(b, "firefox", "https://login.example.com")["error"], "no-match")
        r = fill(b, "firefox", "https://github.com")
        self.assertEqual(r["username"], "jacob-work")
        self.assertEqual(env.choosers(), [])
        self.assertEqual(lines(env.op_log)[0][-2:], ["--vault", V2])

    def test_account_flag(self):
        env = Env(op={"account": "my.1password.com"})
        fill(env.broker(), "firefox", "https://login.example.com")
        for l in lines(env.op_log):
            self.assertEqual(l[-2:], ["--account", "my.1password.com"])

    def test_launcher(self):
        env = Env()
        log = os.path.join(env.dir, "launcher.log")
        env.cfg["op"]["launcher"] = [sys.executable, FAKE_LAUNCHER]
        env.cfg["op"]["extraEnv"]["FAKE_LAUNCHER_LOG"] = log
        self.assertTrue(fill(env.broker(), "firefox", "https://login.example.com")["ok"])
        with open(log) as f:
            self.assertEqual(f.read().split(), [FAKE_OP, FAKE_OP])  # list, then get
        self.assertEqual(len(lines(env.op_log)), 2)

    def test_op_failure(self):
        os.remove(self.env.db)
        self.assertEqual(fill(self.b, "firefox", "https://login.example.com")["error"], "unavailable")

    def test_op_env_is_minimal(self):
        os.environ["SOME_BROWSER_SECRET"] = "x"
        try:
            b = self.env.broker()
            self.assertNotIn("SOME_BROWSER_SECRET", b.op.env)
            self.assertEqual(b.op.env.get("OP_BIOMETRIC_UNLOCK_ENABLED"), "true")
            sa = ob.Broker(self.env.cfg, token="ops_x")
            self.assertEqual(sa.op.env["OP_SERVICE_ACCOUNT_TOKEN"], "ops_x")
            self.assertNotIn("OP_BIOMETRIC_UNLOCK_ENABLED", sa.op.env)
        finally:
            del os.environ["SOME_BROWSER_SECRET"]

    def test_bad_ids_never_reach_op(self):
        with self.assertRaises(ob.OpError):
            self.b.op.get_fields("--help" + "a" * 20, V1, {"password"})
        with self.assertRaises(ob.OpError):
            self.b.op.get_fields(A + "\n", V1, {"password"})
        self.assertEqual(lines(self.env.op_log), [])


# ── Sockets ──────────────────────────────────────────────────────────────────


def rpc(sock, obj):
    sock.sendall(json.dumps(obj).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        c = sock.recv(65536)
        if not c:
            return None
        buf += c
    return json.loads(buf.split(b"\n", 1)[0])


def connect(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(path)
    return s


class TestSockets(unittest.TestCase):
    def test_serve(self):
        env = Env()
        b = env.broker()
        ob.run_serve(b, block=False)
        s = connect(env.cfg["clients"]["firefox"]["socket"])
        self.assertEqual(rpc(s, {"v": 1, "op": "hello", "id": 1}), {"ok": True, "requester": "Firefox (test)", "v": 1, "id": 1})
        r = rpc(s, {"v": 1, "op": "fill", "id": 2, "origin": "https://login.example.com", "want": ["password"]})
        self.assertEqual(r["password"], "example-pw")
        self.assertEqual(r["id"], 2)
        # A claimed identity in the request changes nothing: it is refused.
        self.assertEqual(rpc(s, {"v": 1, "op": "hello", "requester": "chromium"})["error"], "bad-request")
        # Same connection keeps working; garbage lines get bad-request.
        s.sendall(b"garbage\n")
        buf = s.recv(4096)
        self.assertIn(b"bad-request", buf)
        # The other client's socket names the other requester.
        s2 = connect(env.cfg["clients"]["chromium"]["socket"])
        self.assertEqual(rpc(s2, {"v": 1, "op": "hello"})["requester"], "Chromium (test)")
        # An over-long line drops the connection.
        s2.sendall(b"x" * (ob.MAX_REQUEST + 10))
        self.assertEqual(s2.recv(10), b"")
        s.close()
        s2.close()

    def test_peer_check_refuses(self):
        env = Env()
        env.cfg["clients"]["firefox"]["users"] = [os.getuid() + 12345]
        env.cfg["clients"]["chromium"]["cgroup"] = r"/system\.slice/nothing-like-this\.service"
        ob.run_serve(env.broker(), block=False)
        for name in ("firefox", "chromium"):
            s = connect(env.cfg["clients"][name]["socket"])
            try:
                s.sendall(b'{"v":1,"op":"hello"}\n')
                got = s.recv(100)
            except ConnectionResetError:
                got = b""
            self.assertEqual(got, b"", name)
            s.close()
        refused = [l for l in lines(env.audit) if l["event"] == "refused"]
        self.assertEqual(len(refused), 2)

    def test_native_host(self):
        env = Env()
        ob.run_serve(env.broker(), block=False)
        p = subprocess.Popen(
            [sys.executable, NATIVE_HOST],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            env=dict(os.environ, OP_BROKER_SOCKET=env.cfg["clients"]["firefox"]["socket"]),
        )

        def send(obj):
            data = json.dumps(obj).encode()
            p.stdin.write(struct.pack("=I", len(data)) + data)
            p.stdin.flush()
            (n,) = struct.unpack("=I", p.stdout.read(4))
            return json.loads(p.stdout.read(n))

        self.assertEqual(send({"v": 1, "op": "hello", "id": 5})["requester"], "Firefox (test)")
        r = send({"v": 1, "op": "fill", "id": 6, "origin": "https://login.example.com", "want": ["username", "password"]})
        self.assertEqual((r["id"], r["username"], r["password"]), (6, "me@example.com", "example-pw"))
        self.assertEqual(send([1, 2])["error"], "bad-request")
        # Oversized message: the host exits rather than buffering it.
        p.stdin.write(struct.pack("=I", 1 << 20))
        p.stdin.flush()
        self.assertEqual(p.wait(timeout=10), 1)

    def test_native_host_broker_down(self):
        p = subprocess.run(
            [sys.executable, NATIVE_HOST],
            input=struct.pack("=I", 20) + b'{"v":1,"op":"hello"}',
            stdout=subprocess.PIPE,
            env=dict(os.environ, OP_BROKER_SOCKET="/nonexistent/sock"),
            timeout=10,
        )
        (n,) = struct.unpack("=I", p.stdout[:4])
        self.assertEqual(json.loads(p.stdout[4 : 4 + n])["error"], "unavailable")

    def test_bridge_and_uplink(self):
        env = Env()
        d = env.dir
        os.makedirs(os.path.join(d, "bridge", "uplink"))
        os.makedirs(os.path.join(d, "bridge", "firefox"))
        bridge_cfg = {
            "clients": {
                "firefox": {"socket": os.path.join(d, "bridge", "firefox", "sock"), "users": [os.getuid()]},
            },
            "uplink": {"socket": os.path.join(d, "bridge", "uplink", "sock"), "users": [os.getuid()], "wait": 3},
        }
        ob.run_bridge(bridge_cfg, block=False)
        b = env.broker()
        ob.run_uplink(b, bridge_cfg["uplink"]["socket"], pool=2, block=False)
        time.sleep(0.3)
        socks = []
        # More concurrent sessions than the pool: replacements keep up.
        for i in range(4):
            s = connect(bridge_cfg["clients"]["firefox"]["socket"])
            socks.append(s)
            self.assertEqual(rpc(s, {"v": 1, "op": "hello"})["requester"], "Firefox (test)", i)
        r = rpc(socks[0], {"v": 1, "op": "fill", "origin": "https://login.example.com", "want": ["password"]})
        self.assertEqual(r["password"], "example-pw")
        for s in socks:
            s.close()

    def test_bridge_without_uplink(self):
        env = Env()
        d = env.dir
        os.makedirs(os.path.join(d, "b2", "uplink"))
        os.makedirs(os.path.join(d, "b2", "x"))
        cfg = {
            "clients": {"x": {"socket": os.path.join(d, "b2", "x", "sock")}},
            "uplink": {"socket": os.path.join(d, "b2", "uplink", "sock"), "wait": 0.2},
        }
        ob.run_bridge(cfg, block=False)
        s = connect(cfg["clients"]["x"]["socket"])
        self.assertEqual(json.loads(s.recv(4096))["error"], "unavailable")

    def test_uplink_rejects_unknown_client(self):
        env = Env()
        path = os.path.join(env.dir, "up.sock")
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        srv.listen(4)
        ob.run_uplink(env.broker(), path, pool=1, block=False)
        conn, _ = srv.accept()
        conn.settimeout(5)
        conn.sendall(b'{"v":1,"client":"nosuch"}\n')
        self.assertEqual(conn.recv(10), b"")
        # It dials again after refusing.
        conn2, _ = srv.accept()
        conn2.sendall(b'{"v":1,"client":"chromium"}\n')
        self.assertEqual(rpc(conn2, {"v": 1, "op": "hello"})["requester"], "Chromium (test)")


if __name__ == "__main__":
    unittest.main()
