"""op-broker: hands single 1Password logins to sandboxed browsers, one approved
item at a time, for the origin the user was shown.

Runs next to 1Password (same uid / same VM), never in a browser sandbox. See
docs/op-broker.md for the design; in short:

  serve   listen on one unix socket per client sandbox. WHICH socket a connection
          arrived on is the requester's identity (plus an optional peer uid /
          cgroup check); nothing the client says about itself is trusted.
  uplink  the same broker inside a 1Password VM: dial out to the host (over the
          VM's vsock relay) and serve whichever client the host bridge pairs each
          connection with.
  bridge  host side of `uplink`: per-client sockets, paired with idle uplinks,
          each prefixed with one header line naming the client.

Wire protocol (client <-> broker): one JSON object per line, UTF-8, one reply
line per request, requests served in order.

  {"v":1,"op":"hello"}                        -> {"v":1,"ok":true,"requester":...}
  {"v":1,"op":"fill","origin":"https://a.b",  -> {"v":1,"ok":true,"title":...,
   "top":"https://c.d"?, "want":["username",       "username":...,"password":...,
   "password","totp"], "id":N?}                    "totp":...}
                                              or {"v":1,"ok":false,"error":CODE}

Every fill needs an approval from the user (sbx-prompt) naming the requester,
the item and the origin, unless the user answered "allow until it stops" for
that item and origin earlier in the requester's session.
"""

import argparse
import collections
import json
import os
import pwd
import re
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.parse

PROTO = 1
MAX_REQUEST = 16 * 1024  # one request line from a client
MAX_HEADER = 512  # the bridge's header line on an uplink
MAX_OP_OUTPUT = 32 * 1024 * 1024
FIELDS = ("username", "password", "totp")
FIELD_NAMES = {"username": "username", "password": "password", "totp": "one-time code"}
ERRORS = (
    "bad-request",
    "no-match",
    "denied",
    "busy",
    "rate-limited",
    "cooldown",
    "unavailable",
    "internal",
)

# 1Password item and vault ids: 26 lowercase base32-ish characters.
# All of these are used with fullmatch() (never match() with ^...$: Python's $
# also matches before a trailing newline).
OP_ID_RE = re.compile(r"[a-z0-9]{26}")
CLIENT_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
# Uplink mode: at most this many clients taken from the bridge's headers.
MAX_ADDED_CLIENTS = 64
LABEL_RE = re.compile(r"(?!-)[a-z0-9-]{1,63}(?<!-)")
IPV4_RE = re.compile(r"(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}")
IPV6_RE = re.compile(r"\[[0-9a-f:.]{2,45}\]")
ORIGIN_RE = re.compile(r"(https?)://([a-z0-9.-]+|\[[0-9a-f:.]+\])(?::([0-9]{1,5}))?")
DEFAULT_PORT = {"http": 80, "https": 443}


class BadRequest(Exception):
    pass


class OpError(Exception):
    pass


# ── Logging ──────────────────────────────────────────────────────────────────


class Audit:
    """JSON lines to stderr (the journal) and, optionally, an append-only file.
    Never given a secret: callers pass metadata only."""

    def __init__(self, path=None):
        self.lock = threading.Lock()
        self.fh = None
        if path:
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_CLOEXEC, 0o600)
            self.fh = os.fdopen(fd, "a", encoding="utf-8")

    def __call__(self, event, **kw):
        rec = {"t": round(time.time(), 3), "event": event}
        rec.update(kw)
        line = json.dumps(rec, ensure_ascii=True, sort_keys=True)
        with self.lock:
            print(f"op-broker: {line}", file=sys.stderr, flush=True)
            if self.fh:
                self.fh.write(line + "\n")
                self.fh.flush()


audit = Audit()


# ── Origins and item URLs ────────────────────────────────────────────────────


class Origin:
    __slots__ = ("scheme", "host", "port")

    def __init__(self, scheme, host, port):
        self.scheme, self.host, self.port = scheme, host, port  # port None = default

    def __str__(self):
        return f"{self.scheme}://{self.host}" + (f":{self.port}" if self.port is not None else "")

    def __eq__(self, other):
        return isinstance(other, Origin) and str(self) == str(other)

    def __hash__(self):
        return hash(str(self))


def valid_host(host):
    if IPV4_RE.fullmatch(host) or IPV6_RE.fullmatch(host):
        return True
    if len(host) > 253 or host.endswith("."):
        return False
    labels = host.split(".")
    return all(LABEL_RE.fullmatch(label) for label in labels) and not host.replace(".", "").isdigit()


def is_ip(host):
    return bool(IPV4_RE.fullmatch(host) or IPV6_RE.fullmatch(host))


def parse_origin(value, allow_http=False):
    """A web origin as the browser serializes it (URL.origin): lowercase scheme and
    host, punycode (never raw Unicode), no path/userinfo. Anything else is refused
    rather than normalized, so what the user is shown is exactly what was sent."""
    if not isinstance(value, str) or len(value) > 300:
        raise BadRequest("origin")
    m = ORIGIN_RE.fullmatch(value)
    if not m:
        raise BadRequest("origin")
    scheme, host, port = m.group(1), m.group(2), m.group(3)
    if scheme == "http" and not allow_http:
        raise BadRequest("origin: http not allowed")
    if not valid_host(host):
        raise BadRequest("origin: host")
    if port is not None:
        if port.startswith("0"):
            raise BadRequest("origin: port")
        port = int(port)
        if not 1 <= port <= 65535:
            raise BadRequest("origin: port")
        if port == DEFAULT_PORT[scheme]:
            # URL.origin never includes the default port.
            raise BadRequest("origin: default port")
    return Origin(scheme, host, port)


def parse_item_url(href):
    """An item's saved website. These come from the vault and are free-form
    ("github.com", "https://GitHub.com/login"), so they are normalized leniently;
    anything that doesn't reduce to an http(s) host is ignored."""
    if not isinstance(href, str):
        return None
    href = href.strip()
    if not href or len(href) > 2048:
        return None
    if "://" not in href:
        href = "https://" + href
    try:
        parts = urllib.parse.urlsplit(href)
        scheme = parts.scheme.lower()
        host = parts.hostname
        port = parts.port
    except ValueError:
        return None
    if scheme not in DEFAULT_PORT or not host:
        return None
    host = host.rstrip(".")
    if ":" in host:
        host = f"[{host}]"
    if not host.isascii():
        try:
            host = host.encode("idna").decode("ascii")
        except UnicodeError:
            return None
    host = host.lower()
    if not valid_host(host):
        return None
    if port == DEFAULT_PORT[scheme]:
        port = None
    return Origin(scheme, host, port)


def url_matches(origin, item, mode):
    """Whether a login saved for `item` may be offered to `origin`.

    - scheme: an https item never goes to an http page; an http item may go to
      the https version of the same site.
    - port: must be equal (both default, or the same explicit port).
    - host: equal, or (mode "subdomain") the page is a subdomain of the saved
      host, e.g. saved "github.com" fills on "gist.github.com" but saved
      "login.example.com" never fills on "example.com" or "evil.example.com".
      Without a public-suffix list a single-label or IP host matches exactly only.
    """
    if item.scheme == "https" and origin.scheme != "https":
        return False
    if item.port != origin.port:
        return False
    if origin.host == item.host:
        return True
    if mode != "subdomain" or is_ip(item.host) or "." not in item.host:
        return False
    return origin.host.endswith("." + item.host)


def match_rank(origin, item):
    """Lower is better: exact host before subdomain."""
    return 0 if origin.host == item.host else 1


def best_match(origin, urls, mode):
    """(rank, saved Origin) of an item's best-matching saved URL for `origin`,
    or None. Rank 0 is the page's own host, 1 a subdomain of the saved host."""
    best = None
    for u in urls:
        if url_matches(origin, u, mode):
            r = match_rank(origin, u)
            if best is None or r < best[0]:
                best = (r, u)
    return best


# ── Display ──────────────────────────────────────────────────────────────────


def clean(text, limit=80):
    """For the dialog: no control, format (bidi override) or separator
    characters, bounded length. The dialog itself shows plain text."""
    if not isinstance(text, str):
        return ""
    out = []
    for ch in text:
        cat = unicodedata.category(ch)
        if cat[0] == "C" or cat in ("Zl", "Zp"):
            out.append("?" if cat != "Cc" or ch not in "\t\n" else " ")
        else:
            out.append(ch)
    s = "".join(out).strip()
    return s if len(s) <= limit else s[: limit - 1] + "…"


# ── Requests ─────────────────────────────────────────────────────────────────


def parse_request(line, allow_http=False):
    try:
        req = json.loads(line)
    except (ValueError, UnicodeDecodeError):
        raise BadRequest("json")
    if not isinstance(req, dict):
        raise BadRequest("not an object")
    if req.get("v") != PROTO:
        raise BadRequest("version")
    rid = req.get("id")
    if rid is not None and (type(rid) is not int or not 0 <= rid < 2**31):
        raise BadRequest("id")
    op = req.get("op")
    if op == "hello":
        allowed = {"v", "op", "id"}
    elif op == "fill":
        allowed = {"v", "op", "id", "origin", "top", "want"}
    else:
        raise BadRequest("op")
    extra = set(req) - allowed
    if extra:
        raise BadRequest("unknown keys")
    out = {"op": op, "id": rid}
    if op == "fill":
        out["origin"] = parse_origin(req.get("origin"), allow_http)
        top = req.get("top")
        out["top"] = None if top is None else parse_origin(top, allow_http)
        if out["top"] == out["origin"]:
            out["top"] = None
        want = req.get("want")
        if (
            not isinstance(want, list)
            or not want
            or len(want) > len(FIELDS)
            or any(w not in FIELDS for w in want)
            or len(set(want)) != len(want)
        ):
            raise BadRequest("want")
        out["want"] = frozenset(want)
    return out


# ── 1Password CLI ────────────────────────────────────────────────────────────


class Op:
    """The only place `op` runs: fixed argument lists, validated ids, bounded
    output, a minimal environment. Listing returns metadata only; secrets are
    fetched for exactly one item after it was approved."""

    def __init__(self, cfg, token=None):
        self.path = cfg["path"]
        # Run op under this (e.g. a root-owned copy of `timeout` in a VM guest:
        # 1Password checks that the CLI's binary and its parent's are owned by
        # root and not on FUSE; a guest's virtio-fs /nix/store is FUSE, with the
        # host's root-owned files showing up as nobody's).
        self.launcher = [str(a) for a in cfg.get("launcher") or []]
        self.account = cfg.get("account")
        self.vaults = list(cfg.get("vaults") or [])
        self.timeout = int(cfg.get("timeout", 30))
        env = {"LANG": "C.UTF-8", "OP_FORMAT": "json"}
        for key in ("HOME", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME"):
            if os.environ.get(key):
                env[key] = os.environ[key]
        if cfg.get("configDir"):
            env["OP_CONFIG_DIR"] = cfg["configDir"]
        if cfg.get("desktopIntegration", True) and not token:
            env["OP_BIOMETRIC_UNLOCK_ENABLED"] = "true"
        if token:
            env["OP_SERVICE_ACCOUNT_TOKEN"] = token
        env.update({k: str(v) for k, v in (cfg.get("extraEnv") or {}).items()})
        self.env = env
        self.list_ttl = float(cfg.get("listCacheTtl", 60))
        self._list_cache = None
        self._list_lock = threading.Lock()

    def _run(self, args):
        argv = self.launcher + [self.path] + args
        if self.account:
            argv += ["--account", self.account]
        try:
            p = subprocess.run(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=self.env,
                timeout=self.timeout,
                close_fds=True,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            raise OpError(f"op failed to run: {type(e).__name__}")
        if p.returncode != 0:
            msg = clean(p.stderr.decode("utf-8", "replace"), 300)
            raise OpError(f"op exited {p.returncode}: {msg}")
        if len(p.stdout) > MAX_OP_OUTPUT:
            raise OpError("op output too large")
        return p.stdout

    def _json(self, args):
        try:
            return json.loads(self._run(args))
        except ValueError:
            raise OpError("op returned invalid JSON")

    def list_logins(self):
        """[(item_id, vault_id, vault_name, title, subtitle, [Origin])], cached
        briefly (metadata only)."""
        with self._list_lock:
            now = time.monotonic()
            if self._list_cache and now - self._list_cache[0] < self.list_ttl:
                return self._list_cache[1]
            raw = []
            for vault in self.vaults or [None]:
                args = ["item", "list", "--categories", "Login", "--format", "json"]
                if vault is not None:
                    args += ["--vault", vault]
                data = self._json(args)
                if not isinstance(data, list):
                    raise OpError("op item list: not a list")
                raw.extend(data)
            items = []
            for it in raw:
                if not isinstance(it, dict):
                    continue
                iid = it.get("id")
                vault = it.get("vault") if isinstance(it.get("vault"), dict) else {}
                vid = vault.get("id")
                if not (isinstance(iid, str) and OP_ID_RE.fullmatch(iid)):
                    continue
                if not (isinstance(vid, str) and OP_ID_RE.fullmatch(vid)):
                    continue
                urls = []
                for u in it.get("urls") or []:
                    if isinstance(u, dict):
                        o = parse_item_url(u.get("href"))
                        if o is not None:
                            urls.append(o)
                if not urls:
                    continue
                items.append(
                    (
                        iid,
                        vid,
                        clean(vault.get("name", ""), 40),
                        clean(it.get("title", ""), 60) or "(untitled)",
                        clean(it.get("additional_information", ""), 60),
                        urls,
                    )
                )
            self._list_cache = (now, items)
            return items

    def get_fields(self, item_id, vault_id, want):
        if not OP_ID_RE.fullmatch(item_id) or not OP_ID_RE.fullmatch(vault_id):
            raise OpError("bad id")
        data = self._json(["item", "get", item_id, "--vault", vault_id, "--format", "json", "--reveal"])
        if not isinstance(data, dict) or data.get("id") != item_id:
            raise OpError("op item get: unexpected item")
        out = {}
        has_otp = False
        for f in data.get("fields") or []:
            if not isinstance(f, dict):
                continue
            value = f.get("value")
            purpose = f.get("purpose")
            if purpose == "USERNAME" and "username" in want and isinstance(value, str):
                out.setdefault("username", value)
            elif purpose == "PASSWORD" and "password" in want and isinstance(value, str):
                out.setdefault("password", value)
            elif f.get("type") == "OTP":
                has_otp = True
                if "totp" in want and isinstance(f.get("totp"), str):
                    out.setdefault("totp", f["totp"])
        if "totp" in want and "totp" not in out and has_otp:
            code = self._run(["item", "get", item_id, "--vault", vault_id, "--otp"])
            code = code.decode("utf-8", "replace").strip()
            if code:
                out["totp"] = code
        for k, v in list(out.items()):
            if not isinstance(v, str) or len(v) > 4096:
                del out[k]
        if "totp" in out and not re.fullmatch(r"[0-9A-Za-z]{4,16}", out["totp"]):
            del out["totp"]
        return out


# ── Policy state ─────────────────────────────────────────────────────────────


class Limiter:
    """Per requester: a token bucket (every fill, hit or miss, costs one), an
    hourly cap, and a cooldown after repeated denials, so a compromised browser
    can neither flood the user with dialogs nor enumerate origins quickly."""

    def __init__(self, cfg):
        self.burst = float(cfg.get("burst", 5))
        self.per_minute = float(cfg.get("perMinute", 10))
        self.per_hour = int(cfg.get("perHour", 120))
        self.deny_limit = int(cfg.get("denyLimit", 3))
        self.deny_cooldown = float(cfg.get("denyCooldown", 300))
        self.lock = threading.Lock()
        self.state = {}

    def _st(self, who, now):
        st = self.state.get(who)
        if st is None:
            st = self.state[who] = {
                "tokens": self.burst,
                "at": now,
                "hour": collections.deque(),
                "denials": 0,
                "until": 0.0,
            }
        return st

    def take(self, who, now=None):
        """None if allowed, else the error code."""
        now = time.monotonic() if now is None else now
        with self.lock:
            st = self._st(who, now)
            if now < st["until"]:
                return "cooldown"
            st["tokens"] = min(self.burst, st["tokens"] + (now - st["at"]) * self.per_minute / 60.0)
            st["at"] = now
            hour = st["hour"]
            while hour and now - hour[0] >= 3600:
                hour.popleft()
            if st["tokens"] < 1 or len(hour) >= self.per_hour:
                return "rate-limited"
            st["tokens"] -= 1
            hour.append(now)
            return None

    def denied(self, who, now=None):
        now = time.monotonic() if now is None else now
        with self.lock:
            st = self._st(who, now)
            st["denials"] += 1
            if st["denials"] >= self.deny_limit:
                st["denials"] = 0
                st["until"] = now + self.deny_cooldown
                return True
            return False

    def allowed(self, who):
        with self.lock:
            st = self.state.get(who)
            if st:
                st["denials"] = 0

    def block(self, who, seconds, now=None):
        """Refuse every request from `who` (as a cooldown) for `seconds`."""
        now = time.monotonic() if now is None else now
        with self.lock:
            st = self._st(who, now)
            st["until"] = max(st["until"], now + seconds)


class ProbeWatch:
    """Notices a requester that looks like it is probing which sites have a
    saved login: several different origins with no match in a short window, or
    hitting the rate limit. A `no-match` answer needs no dialog, so without this
    a compromised browser could enumerate your accounts silently (at the rate
    limit). The notice is itself rate-limited per requester, so it can't be used
    to flood the screen either."""

    def __init__(self, cfg):
        self.distinct = max(1, int(cfg.get("distinct", 4)))
        self.window = float(cfg.get("window", 120))
        self.interval = float(cfg.get("interval", 600))
        self.lock = threading.Lock()
        self.seen = {}  # who -> deque[(t, origin)]
        self.last = {}  # who -> time of the last notice

    def _recent(self, who, now, origin):
        dq = self.seen.setdefault(who, collections.deque())
        if origin is not None:
            dq.append((now, str(origin)))
        while dq and (now - dq[0][0] > self.window or len(dq) > 256):
            dq.popleft()
        out = []
        for _, o in dq:
            if o in out:
                out.remove(o)
            out.append(o)
        return out  # distinct, oldest first

    def _due(self, who, now):
        last = self.last.get(who)
        if last is not None and now - last < self.interval:
            return False
        self.last[who] = now
        return True

    def miss(self, who, origin, now=None):
        """A no-match for `origin`. Returns the distinct recent origins when a
        notice is due, else None."""
        now = time.monotonic() if now is None else now
        with self.lock:
            recent = self._recent(who, now, origin)
            if len(recent) >= self.distinct and self._due(who, now):
                return recent
            return None

    def limited(self, who, origin, now=None):
        """A request refused by the rate limit: worth a notice by itself (at
        most one per interval). Returns the recent no-match origins plus this
        one (whose match wasn't looked up)."""
        now = time.monotonic() if now is None else now
        with self.lock:
            recent = self._recent(who, now, None)
            if not self._due(who, now):
                return None
            o = str(origin)
            return [x for x in recent if x != o] + [o]


class Sessions:
    """"Allow until it stops" answers. A requester's session lasts while it has a
    connection open, plus a grace period after its last one closes (the browser's
    native-messaging port comes and goes with its background page), and never
    longer than sessionMax."""

    def __init__(self, cfg):
        self.idle = float(cfg.get("sessionIdle", 300))
        self.max = float(cfg.get("sessionMax", 8 * 3600))
        self.lock = threading.Lock()
        self.conns = collections.Counter()
        self.last_close = {}
        self.grants = {}  # (who, item, origin) -> (fields, granted_at)

    def opened(self, who):
        with self.lock:
            self.conns[who] += 1

    def closed(self, who, now=None):
        now = time.monotonic() if now is None else now
        with self.lock:
            self.conns[who] -= 1
            if self.conns[who] <= 0:
                del self.conns[who]
                self.last_close[who] = now

    def _alive(self, who, now):
        if self.conns.get(who, 0) > 0:
            return True
        last = self.last_close.get(who)
        return last is not None and now - last < self.idle

    def grant(self, who, item_id, origin, fields, now=None):
        now = time.monotonic() if now is None else now
        with self.lock:
            key = (who, item_id, str(origin))
            prev = self.grants.get(key)
            if prev and now - prev[1] < self.max:
                fields = prev[0] | fields
            self.grants[key] = (frozenset(fields), now)

    def covers(self, who, item_id, origin, fields, now=None):
        now = time.monotonic() if now is None else now
        with self.lock:
            if not self._alive(who, now):
                for k in [k for k in self.grants if k[0] == who]:
                    del self.grants[k]
                return False
            g = self.grants.get((who, item_id, str(origin)))
            if not g:
                return False
            if now - g[1] >= self.max:
                del self.grants[(who, item_id, str(origin))]
                return False
            return fields <= g[0]


# ── The broker ───────────────────────────────────────────────────────────────


class Broker:
    def __init__(self, cfg, op=None, token=None):
        self.cfg = cfg
        self.clients = cfg["clients"]
        for name in self.clients:
            if not CLIENT_RE.fullmatch(name):
                raise SystemExit(f"op-broker: bad client name {name!r}")
        match = cfg.get("match") or {}
        self.mode = match.get("mode", "subdomain")
        if self.mode not in ("exact", "subdomain"):
            raise SystemExit("op-broker: match.mode must be exact or subdomain")
        self.allow_http = bool(match.get("allowHttp", False))
        prompt = cfg.get("prompt") or {}
        self.prompt_cmd = list(prompt["command"])
        self.chooser_cmd = list(prompt.get("chooser") or [])
        self.prompt_timeout = int(prompt.get("timeout", 60))
        self.allow_session = bool(prompt.get("allowSession", True))
        self.queue_wait = float(prompt.get("queueWait", 5))
        self.max_candidates = int(prompt.get("maxCandidates", 12))
        # The probing notice (op-broker-notice); none configured: audit only.
        self.notice_cmd = list(prompt.get("notice") or [])
        limits = cfg.get("limits") or {}
        self.limiter = Limiter(limits)
        self.sessions = Sessions(limits)
        probe = cfg.get("probe") or {}
        self.probes = ProbeWatch(probe)
        self.probe_block = float(probe.get("block", 3600))
        self.notice_lock = threading.Lock()  # one notice on screen at a time
        self.op = op or Op(dict(cfg["op"], listCacheTtl=limits.get("listCacheTtl", 60)), token=token)
        self.dialog = threading.Lock()  # one dialog on screen at a time
        self.inflight_lock = threading.Lock()
        self.inflight = set()

    def label(self, who):
        return clean(self.clients[who].get("label") or who, 60)

    # Dialogs. Both commands get argument lists (no shell), and everything shown
    # was cleaned above; REQUESTER is the broker's own label for the client.
    def _prompt(self, who, summary, detail):
        argv = list(self.prompt_cmd) + ["--timeout", str(self.prompt_timeout)]
        if not self.allow_session:
            argv.append("--no-session")
        argv += ["--", self.label(who), summary, detail]
        try:
            p = subprocess.run(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=self.prompt_timeout + 15,
                close_fds=True,
            )
        except (OSError, subprocess.TimeoutExpired):
            return "deny"
        answer = p.stdout.decode("ascii", "replace").strip()
        if p.returncode == 0 and answer in ("once", "session"):
            if answer == "session" and not self.allow_session:
                return "once"
            return answer
        return "deny"

    def _choose(self, who, text, options):
        if not self.chooser_cmd:
            return None
        argv = list(self.chooser_cmd) + ["--timeout", str(self.prompt_timeout), "--", self.label(who), text]
        argv += options
        try:
            p = subprocess.run(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=self.prompt_timeout + 15,
                close_fds=True,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        out = p.stdout.decode("ascii", "replace").strip()
        if p.returncode != 0 or not out.isdigit():
            return None
        idx = int(out)
        return idx if 0 <= idx < len(options) else None

    # ── Probing notice ──
    def _probe_notice(self, who, origins, why):
        """Tell the user `who` looks like it's probing for saved logins. Runs in
        the background (the request is answered meanwhile); at most one notice
        per requester per interval (ProbeWatch) and one on screen at a time."""
        shown = origins[-8:]
        audit("probe-notice", requester=who, reason=why, origins=shown, count=len(origins))
        if not self.notice_cmd:
            return None
        if why == "rate-limited":
            summary = "sent more login requests than a person filling forms would"
        else:
            summary = "asked for logins on several sites that have none saved"
        mins = max(1, round(self.probes.window / 60))
        lines = [
            "This can mean it is probing which sites you have accounts on.",
            "Nothing was filled. All it learned is that no login is saved for:",
        ]
        lines += [f"  {o}" for o in shown]
        if len(origins) > len(shown):
            lines.append(f"  … and {len(origins) - len(shown)} more")
        lines.append(f"({len(origins)} sites in the last {mins} min.)")
        if why == "rate-limited":
            lines.append("The request that hit the limit was refused without a lookup.")
        detail = "\n".join(lines)

        def run():
            if not self.notice_lock.acquire(blocking=False):
                return
            try:
                argv = list(self.notice_cmd) + ["--timeout", str(max(self.prompt_timeout, 120))]
                argv += ["--", self.label(who), summary, detail]
                try:
                    p = subprocess.run(
                        argv,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        timeout=max(self.prompt_timeout, 120) + 15,
                        close_fds=True,
                    )
                    answer = p.stdout.decode("ascii", "replace").strip()
                except (OSError, subprocess.TimeoutExpired):
                    answer = ""
                if answer == "block":
                    self.limiter.block(who, self.probe_block)
                    audit("probe-block", requester=who, seconds=self.probe_block)
            finally:
                self.notice_lock.release()

        t = threading.Thread(target=run, daemon=True)
        t.start()
        return t

    def handle(self, who, req, peer=None):
        """Serve one parsed request for requester `who`. Returns the reply dict."""
        if req["op"] == "hello":
            return {"ok": True, "requester": self.label(who)}
        with self.inflight_lock:
            if who in self.inflight:
                return {"ok": False, "error": "busy"}
            self.inflight.add(who)
        try:
            return self._fill(who, req, peer)
        finally:
            with self.inflight_lock:
                self.inflight.discard(who)

    def _fill(self, who, req, peer):
        origin, top, want = req["origin"], req["top"], req["want"]
        base = {"requester": who, "origin": str(origin), "want": sorted(want)}
        if top is not None:
            base["top"] = str(top)
        if peer:
            base["peer"] = peer
        limited = self.limiter.take(who)
        if limited:
            audit("fill", decision=limited, **base)
            if limited == "rate-limited":
                recent = self.probes.limited(who, origin)
                if recent:
                    self._probe_notice(who, recent, "rate-limited")
            return {"ok": False, "error": limited}
        try:
            items = self.op.list_logins()
        except OpError as e:
            audit("fill", decision="unavailable", reason=str(e), **base)
            return {"ok": False, "error": "unavailable"}
        # Candidates: (item, rank, the saved URL it matched on). Rank 0 is the
        # page's own host, 1 a subdomain of the saved host (shown as such).
        cands = []
        for it in items:
            m = best_match(origin, it[5], self.mode)
            if m is not None:
                cands.append((m[0], it[3].lower(), (it, m[0], m[1])))
        cands.sort(key=lambda c: (c[0], c[1]))
        cands = [c[2] for c in cands]
        if not cands:
            audit("fill", decision="no-match", **base)
            recent = self.probes.miss(who, origin)
            if recent:
                self._probe_notice(who, recent, "no-match")
            return {"ok": False, "error": "no-match"}

        # A standing "until it stops" grant for exactly one candidate fills
        # without asking again.
        granted = [c for c in cands if self.sessions.covers(who, c[0][0], origin, want)]
        if len(granted) == 1:
            return self._deliver(who, granted[0], origin, want, "session-cached", base)

        if not self.dialog.acquire(timeout=self.queue_wait):
            audit("fill", decision="busy", **base)
            return {"ok": False, "error": "busy"}
        try:
            chosen = cands[0]
            if len(cands) > 1:
                shown = cands[: self.max_candidates]
                opts = [self._option(c, origin) for c in shown]
                text = f"Choose the login to fill on {origin}" + (
                    f" (embedded in {top})" if top is not None else ""
                )
                if any(c[1] for c in shown):
                    text += "\nLogins marked SUBDOMAIN are saved for a parent site of this page."
                idx = self._choose(who, text, opts)
                if idx is None:
                    self._denied(who)
                    audit("fill", decision="deny", stage="choose", candidates=len(cands), **base)
                    return {"ok": False, "error": "denied"}
                chosen = shown[idx]
            if self.sessions.covers(who, chosen[0][0], origin, want):
                answer = "session-cached"
            else:
                answer = self._prompt(who, *self._prompt_text(chosen, origin, top, want))
        finally:
            self.dialog.release()
        if answer == "deny":
            self._denied(who)
            audit("fill", decision="deny", item=chosen[0][0], title=chosen[0][3], **base)
            return {"ok": False, "error": "denied"}
        self.limiter.allowed(who)
        if answer == "session":
            self.sessions.grant(who, chosen[0][0], origin, want)
        return self._deliver(who, chosen, origin, want, answer, base)

    def _denied(self, who):
        if self.limiter.denied(who):
            audit("cooldown", requester=who, seconds=self.limiter.deny_cooldown)

    def _describe(self, it):
        return f"{it[3]} ({it[4]})" if it[4] else it[3]

    def _option(self, cand, origin):
        """A chooser row: the item, and whether it only matched as a subdomain."""
        it, rank, saved = cand
        text = self._describe(it)
        if rank:
            text += f"  [SUBDOMAIN: saved for {saved.host}, page is {origin.host}]"
        return text

    def _prompt_text(self, cand, origin, top, want):
        it, rank, saved = cand
        fields = ", ".join(FIELD_NAMES[f] for f in FIELDS if f in want)
        summary = f'fill the 1Password login "{self._describe(it)}" on {origin}'
        lines = []
        if rank:
            # Subdomain matching is on by default; make it impossible to miss.
            summary += f"\n  SUBDOMAIN MATCH: saved for {saved.host}, not for {origin.host}"
            lines.append(
                f"This login is saved for {saved}; the page is on {origin.host}, a subdomain of it."
            )
        lines += [f"Fields: {fields}", f"Vault: {it[2] or '?'}"]
        if top is not None:
            lines.append(f"The login form is embedded in a page from {top}.")
        saved_all = ", ".join(str(u) for u in it[5][:3])
        lines.append(f"Saved for: {saved_all}")
        return summary, "\n".join(lines)

    def _deliver(self, who, cand, origin, want, how, base):
        it, rank, _ = cand
        try:
            got = self.op.get_fields(it[0], it[1], want)
        except OpError as e:
            audit("fill", decision="unavailable", item=it[0], reason=str(e), **base)
            return {"ok": False, "error": "unavailable"}
        audit(
            "fill",
            decision=how,
            item=it[0],
            title=it[3],
            match="subdomain" if rank else "exact",
            delivered=sorted(got),
            **base,
        )
        reply = {"ok": True, "title": it[3]}
        reply.update(got)
        return reply

    # ── Connections ──
    def serve_conn(self, conn, who, peer=None):
        self.sessions.opened(who)
        try:
            buf = b""
            while True:
                nl = buf.find(b"\n")
                if nl < 0:
                    if len(buf) > MAX_REQUEST:
                        audit("drop", requester=who, reason="request too long")
                        return
                    try:
                        chunk = conn.recv(4096)
                    except OSError:
                        return
                    if not chunk:
                        return
                    buf += chunk
                    continue
                line, buf = buf[:nl], buf[nl + 1 :]
                if len(line) > MAX_REQUEST:
                    audit("drop", requester=who, reason="request too long")
                    return
                rid = None
                try:
                    req = parse_request(line, self.allow_http)
                    rid = req["id"]
                    reply = self.handle(who, req, peer)
                except BadRequest as e:
                    audit("bad-request", requester=who, reason=str(e))
                    reply = {"ok": False, "error": "bad-request"}
                except Exception as e:  # never let one request kill the broker
                    audit("error", requester=who, reason=type(e).__name__)
                    reply = {"ok": False, "error": "internal"}
                reply["v"] = PROTO
                if rid is not None:
                    reply["id"] = rid
                data = json.dumps(reply, ensure_ascii=True).encode() + b"\n"
                del reply
                try:
                    conn.sendall(data)
                except OSError:
                    return
                finally:
                    del data
        finally:
            self.sessions.closed(who)
            try:
                conn.close()
            except OSError:
                pass


# ── Peer checks and sockets ──────────────────────────────────────────────────


def peer_cred(conn):
    data = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    pid, uid, gid = struct.unpack("3i", data)
    return pid, uid, gid


def peer_cgroup(pid):
    try:
        with open(f"/proc/{pid}/cgroup", encoding="utf-8") as f:
            for line in f:
                if line.startswith("0::"):
                    return line[3:].strip()
    except OSError:
        pass
    return None


def resolve_uids(names):
    out = set()
    for n in names or []:
        if isinstance(n, int):
            out.add(n)
            continue
        try:
            out.add(pwd.getpwnam(n).pw_uid)
        except KeyError:
            audit("config", warning=f"unknown user {n!r}")
    return out


class PeerCheck:
    """Who may connect on a socket: a set of uids (empty = any) and an optional
    regex the peer's cgroup must fully match (e.g. the VM's relay unit, which the
    user can't move processes into)."""

    def __init__(self, spec):
        self.uids = resolve_uids(spec.get("users"))
        self.any_uid = not spec.get("users")
        cg = spec.get("cgroup")
        self.cgroup = re.compile(cg) if cg else None

    def check(self, conn):
        pid, uid, gid = peer_cred(conn)
        info = {"pid": pid, "uid": uid}
        if not self.any_uid and uid not in self.uids:
            return False, info
        if self.cgroup is not None:
            cg = peer_cgroup(pid)
            info["cgroup"] = cg
            if cg is None or not self.cgroup.fullmatch(cg):
                return False, info
        return True, info


def listen_unix(path, mode=0o666):
    d = os.path.dirname(path)
    if not os.path.isdir(d):
        raise SystemExit(f"op-broker: socket directory {d} is missing")
    try:
        st = os.lstat(path)
        if not stat.S_ISSOCK(st.st_mode):
            raise SystemExit(f"op-broker: {path} exists and is not a socket")
        os.unlink(path)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    s.bind(path)
    # Access is decided by the directory (per-client ACL) and the peer check.
    os.chmod(path, mode)
    s.listen(16)
    return s


def accept_loop(sock, check, on_conn, what):
    while True:
        try:
            conn, _ = sock.accept()
        except OSError as e:
            audit("accept-error", socket=what, reason=str(e))
            time.sleep(0.5)
            continue
        try:
            ok, info = check.check(conn)
        except OSError:
            ok, info = False, {}
        if not ok:
            audit("refused", socket=what, **info)
            conn.close()
            continue
        threading.Thread(target=on_conn, args=(conn, info), daemon=True).start()


def notify_ready():
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM | socket.SOCK_CLOEXEC) as n:
        n.connect(addr)
        n.sendall(b"READY=1")


def read_line(conn, limit):
    buf = b""
    while len(buf) <= limit:
        c = conn.recv(1)
        if not c:
            return None
        if c == b"\n":
            return buf
        buf += c
    return None


# ── Modes ────────────────────────────────────────────────────────────────────


def run_serve(broker, block=True):
    threads = []
    for name, spec in broker.clients.items():
        sock = listen_unix(spec["socket"])
        check = PeerCheck(spec)

        def on_conn(conn, info, name=name):
            audit("connect", requester=name, **info)
            broker.serve_conn(conn, name, info)

        t = threading.Thread(target=accept_loop, args=(sock, check, on_conn, name), daemon=True)
        t.start()
        threads.append(t)
    audit("ready", mode="serve", clients=sorted(broker.clients))
    notify_ready()
    for t in threads if block else []:
        t.join()


def run_uplink(broker, path, pool, max_conns=64, block=True):
    """Inside the 1Password VM: keep `pool` idle connections open to the host
    bridge; each waits for a header naming its client, then is that client's
    session (and a fresh idle one replaces it). The header comes from the host
    bridge, never from a browser: the bridge knows which socket the client used."""
    lock = threading.Lock()
    total = [0]
    added = [0]  # clients learned from the bridge (MAX_ADDED_CLIENTS)

    def spawn():
        with lock:
            if total[0] >= max_conns:
                return
            total[0] += 1
        threading.Thread(target=worker, daemon=True).start()

    def worker():
        backoff = 0.5
        try:
            while True:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
                try:
                    s.connect(path)
                    line = read_line(s, MAX_HEADER)
                    if line is None:
                        raise OSError("uplink closed")
                    backoff = 0.5
                    hdr = json.loads(line)
                    if not isinstance(hdr, dict) or hdr.get("v") != PROTO:
                        raise ValueError("bad header")
                    who = hdr.get("client")
                    if who not in broker.clients:
                        # The bridge (host, its own uid: the only peer of this
                        # socket) decides who a connection is; a client added
                        # on the host after this VM started is taken from it.
                        label = hdr.get("label")
                        if (
                            not isinstance(who, str)
                            or not CLIENT_RE.fullmatch(who)
                            or not isinstance(label, str)
                            or not label
                        ):
                            raise ValueError("unknown client")
                        with lock:
                            if who not in broker.clients:
                                if added[0] >= MAX_ADDED_CLIENTS:
                                    raise ValueError("too many added clients")
                                added[0] += 1
                                broker.clients = {**broker.clients, who: {"label": clean(label, 60)}}
                        audit("uplink", added=who)
                except (OSError, ValueError) as e:
                    s.close()
                    if isinstance(e, ValueError):
                        audit("uplink", error=str(e))
                    time.sleep(backoff)
                    backoff = min(backoff * 2, 10)
                    continue
                spawn()  # keep the idle pool full while this one serves
                audit("connect", requester=who, via="uplink")
                broker.serve_conn(s, who, {"via": "uplink"})
                return
        finally:
            with lock:
                total[0] -= 1

    for _ in range(pool):
        spawn()
    audit("ready", mode="uplink", path=path, pool=pool)
    notify_ready()
    while block:
        time.sleep(3600)


def splice(a, b):
    def pump(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    t = threading.Thread(target=pump, args=(b, a), daemon=True)
    t.start()
    pump(a, b)
    t.join()
    a.close()
    b.close()


def uplink_alive(s):
    """An idle uplink has sent nothing; readable means EOF (or garbage)."""
    import select

    r, _, _ = select.select([s], [], [], 0)
    return not r


def run_bridge(cfg, block=True):
    """Host side of uplink mode. Carries bytes only; it holds no secrets and
    makes no decisions except which client a connection came from."""
    import queue

    idle = queue.Queue()
    up = cfg["uplink"]
    up_sock = listen_unix(up["socket"])
    up_check = PeerCheck(up)
    wait = float(up.get("wait", 5))

    def on_uplink(conn, info):
        idle.put(conn)

    threading.Thread(
        target=accept_loop, args=(up_sock, up_check, on_uplink, "uplink"), daemon=True
    ).start()

    def take_uplink():
        deadline = time.monotonic() + wait
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            try:
                s = idle.get(timeout=left)
            except queue.Empty:
                return None
            if uplink_alive(s):
                return s
            s.close()

    threads = []
    for name, spec in cfg["clients"].items():
        if not CLIENT_RE.fullmatch(name):
            raise SystemExit(f"op-broker: bad client name {name!r}")
        sock = listen_unix(spec["socket"])

        def on_conn(conn, info, name=name, spec=spec):
            s = take_uplink()
            if s is None:
                audit("bridge", requester=name, error="no uplink (is 1Password running?)")
                try:
                    conn.sendall(
                        json.dumps({"v": PROTO, "ok": False, "error": "unavailable"}).encode() + b"\n"
                    )
                except OSError:
                    pass
                conn.close()
                return
            try:
                # The label too: a guest broker started before this client was
                # configured (1Password's VM outlives a host rebuild) learns it
                # from here.
                hdr = {"v": PROTO, "client": name, "label": spec.get("label") or name}
                s.sendall(json.dumps(hdr).encode() + b"\n")
            except OSError:
                s.close()
                conn.close()
                return
            audit("bridge", requester=name, **info)
            splice(conn, s)

        t = threading.Thread(
            target=accept_loop, args=(sock, PeerCheck(spec), on_conn, name), daemon=True
        )
        t.start()
        threads.append(t)
    audit("ready", mode="bridge", clients=sorted(cfg["clients"]))
    notify_ready()
    for t in threads if block else []:
        t.join()


def load_config(path):
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict) or not isinstance(cfg.get("clients"), dict):
        raise SystemExit("op-broker: config needs a clients object")
    return cfg


def main(argv=None):
    ap = argparse.ArgumentParser(prog="op-broker")
    sub = ap.add_subparsers(dest="mode", required=True)
    s = sub.add_parser("serve", help="listen on the per-client sockets")
    s.add_argument("--config", required=True)
    s.add_argument("--token-file", help="service-account token (instead of the desktop app)")
    u = sub.add_parser("uplink", help="dial the host bridge (broker inside a 1Password VM)")
    u.add_argument("--config", required=True)
    u.add_argument("--token-file")
    u.add_argument("--path", required=True, help="the uplink socket (the VM relay's guest end)")
    u.add_argument("--pool", type=int, default=4)
    b = sub.add_parser("bridge", help="host side of uplink mode")
    b.add_argument("--config", required=True)
    a = ap.parse_args(argv)

    cfg = load_config(a.config)
    global audit
    audit = Audit((cfg.get("audit") or {}).get("file"))
    if a.mode == "bridge":
        run_bridge(cfg)
        return
    token = None
    if a.token_file:
        with open(a.token_file, encoding="utf-8") as f:
            token = f.read().strip()
        if not token:
            raise SystemExit("op-broker: empty token file")
    broker = Broker(cfg, token=token)
    if a.mode == "serve":
        run_serve(broker)
    else:
        run_uplink(broker, a.path, max(1, a.pool))


if __name__ == "__main__":
    main()
