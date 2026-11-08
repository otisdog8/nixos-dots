"""sbx-dnsallow and sbx-netlocal: the sandboxes' network policy at run time.

One file, two root daemons (one each per host), told apart by the name they
run under; modules/system/sandbox-dnsallow.nix runs both.

sbx-dnsallow: open a sandbox's IP filter to the addresses its allowed names
resolve to. Subscribes to systemd-resolved's query monitor
(io.systemd.Resolve.Monitor.SubscribeQueryResults, varlink) and, whenever a
lookup of a name some sandbox may reach succeeds, adds the answer's A/AAAA
addresses to that sandbox's units. Every update writes the unit's whole list,
its static entries (the rule's `allow`, as in the unit file) and every address
learned for it:

    systemctl set-property --runtime UNIT IPAddressAllow= IPAddressAllow=ADDR...

systemd keeps a runtime property in /run/systemd/system.control/UNIT.d/
50-IPAddressAllow.conf, and that drop-in holds the unit's complete list at the
time and outranks the unit file until reboot. Written piecemeal, it would pin
the static entries of whichever build it was first written under: a rebuild
that changed them would neither open the new ones nor close the removed ones.
So the static list is part of this daemon's config (a change restarts it), and
at startup it writes the current full list for every unit it manages,
replacing whatever an earlier build left there. A unit it managed before that
no rule covers any more is put back to its unit files' own IPAddressAllow=.

The broker's network grants (sbx-attach's allow-ip, lib/broker/attach.py)
land in the same drop-in, so they're part of every write too: sbx-attach
records each in `grants` (GRANTS.json, until reboot like its drop-in), and
both hold GRANTS' lock across reading or recording and their set-property.

Learned addresses are kept in `state` (a runtime directory that outlives the
daemon, until reboot like the drop-ins), so a restart doesn't close a
sandbox's open connections until each name is looked up again. At startup
they're checked again against the current rules: one whose name is no longer
allowed, or is now denied, is dropped. An address not seen in a lookup for
MAX_AGE seconds is dropped at the unit's next update, and a unit keeps at most
MAX_PER_UNIT of them (the most recently seen).

Names: "example.com" (exactly), "*.example.com" (any name under it, not the
name itself). The query that matched may have been made by anyone on the host:
that only ever opens addresses of names the sandbox was allowed anyway.

An allowed name never opens a local address: IPAddressAllow= wins over every
deny (the static ranges and the slice's), so answers in `local` (netpolicy's
static ranges) or in sbx-netlocal's current set of the host's and LAN's public
prefixes (`localFile`) are dropped. While localFile is configured but missing
(sbx-netlocal isn't running), nothing is opened. For the same reason a rule's
own `deny` (the sandbox's policy deny entries) is never opened by its names.

Config (JSON): {"systemctl": PATH, "local": [CIDR...], "localFile": PATH or
null, "state": PATH or null, "grants": DIR or null, "rules": [{"units":
[UNIT or GLOB...], "names": [NAME...], "deny": [CIDR or "any"...], "allow":
[ENTRY...]}]}

`sbx-dnsallow --cleanup CONFIG` (the unit, once no sandbox has allowNames
left): only the startup pass's second half, putting every unit it managed
back to its unit files' list (and grants), then exit.

sbx-netlocal: keep the sandboxes in a restricted network mode off the host's
and LAN's public addresses. netpolicy's static ranges (RFC 1918, ULA, ...)
can't name the host's own global addresses or its LAN's global prefixes: on an
IPv6 LAN the router hands those out, and they change. This one watches the
kernel's addresses and routes (`ip monitor`, plus a rescan every RESCAN
seconds) and keeps the sandboxes' slice denied them:

    systemctl set-property --runtime SLICE IPAddressDeny= IPAddressDeny=PREFIX...

which systemd merges into every member's cgroup IP filter, including members
started later. The slice's own unit file denies "any" until the first update
(fail closed), and the slice is ordered after this service's readiness.

The set: every address on the host (any interface); and, on LAN-like interfaces
(BROADCAST, not POINTOPOINT: ethernet, wifi, bridges; not tunnels, whose routes
are as often the internet itself), each address's prefix, every directly
connected route, and the routes the router advertised (RIO, proto ra). Prefixes
shorter than minPrefix (a VPN's 0.0.0.0/1 halves) are skipped; IPv6 ones are
widened to widen6 bits (the rest of a delegated prefix: the LAN's other
subnets). Whatever a static netpolicy range already covers is left out: those
stay per-unit, where an app's own allow entries can open them.

The current set is also written to STATE (JSON), where sbx-dnsallow checks
allowed names' answers against it.

Config (JSON): {"ip": PATH, "systemctl": PATH, "slice": UNIT, "state": PATH,
"static": [CIDR...], "minPrefix4": N, "minPrefix6": N, "widen6": N or null}

`sbx-netlocal --dry-run CONFIG` prints the set and changes nothing.
"""

import fcntl
import fnmatch
import ipaddress
import json
import os
import select
import socket
import subprocess
import sys
import time

PROG = os.path.basename(sys.argv[0])

MONITOR = "/run/systemd/resolve/io.systemd.Resolve.Monitor"
A, AAAA = 1, 28


def log(msg):
    print(f"{PROG}: {msg}", file=sys.stderr, flush=True)


def norm(name):
    return name.rstrip(".").lower()


def name_matches(name, pattern):
    name, pattern = norm(name), norm(pattern)
    if pattern.startswith("*."):
        return name.endswith(pattern[1:])
    return name == pattern


def rr_address(rr):
    key = rr.get("key") or {}
    if key.get("type") not in (A, AAAA):
        return None
    addr = rr.get("address")
    try:
        if isinstance(addr, list):
            return str(ipaddress.ip_address(bytes(addr)))
        if isinstance(addr, str):
            return str(ipaddress.ip_address(addr))
    except ValueError:
        pass
    return None


def result_names_and_addresses(params):
    """(names asked, addresses answered) for one successful lookup."""
    if params.get("state") != "success":
        return [], []
    names = [
        q.get("name", "")
        for q in (params.get("question") or []) + (params.get("collectedQuestions") or [])
        if isinstance(q, dict)
    ]
    addrs = []
    for item in params.get("answer") or []:
        rr = item.get("rr") if isinstance(item, dict) else None
        a = rr_address(rr) if isinstance(rr, dict) else None
        if a and a not in addrs:
            addrs.append(a)
    return names, addrs


class Local:
    """netpolicy's static ranges plus sbx-netlocal's current set."""

    def __init__(self, static, path):
        self.static = [ipaddress.ip_network(c) for c in static]
        self.path = path
        self.stamp = None
        self.dynamic = []

    def nets(self):
        """The local networks, or None when sbx-netlocal's set can't be read."""
        if not self.path:
            return self.static
        try:
            st = os.stat(self.path)
            stamp = (st.st_ino, st.st_mtime_ns, st.st_size)
            if stamp != self.stamp:
                with open(self.path) as f:
                    self.dynamic = [ipaddress.ip_network(p) for p in json.load(f)["prefixes"]]
                self.stamp = stamp
        except (OSError, ValueError, KeyError, TypeError) as e:
            log(f"{self.path}: {e}")
            self.stamp = None
            return None
        return self.static + self.dynamic

    @staticmethod
    def contains(nets, addr):
        a = ipaddress.ip_address(addr)
        # An IPv4-mapped answer reaches the IPv4 address.
        candidates = [a] + ([a.ipv4_mapped] if a.version == 6 and a.ipv4_mapped else [])
        return any(c.is_unspecified or any(c in n for n in nets) for c in candidates)


def rule_deny(rule):
    """A rule's own deny entries as networks ("any": everything; systemd's
    other names are all in `local` already)."""
    nets = []
    for d in rule.get("deny") or []:
        if d == "any":
            nets += [ipaddress.ip_network("0.0.0.0/0"), ipaddress.ip_network("::/0")]
            continue
        try:
            nets.append(ipaddress.ip_network(d, strict=False))
        except ValueError:
            pass
    return nets


MAX_AGE = 7 * 86400  # seconds a learned address lasts without another lookup
MAX_PER_UNIT = 4096  # learned addresses per unit (the most recently seen)
SAVE_EVERY = 600  # seconds between saves of the state for last-seen times only
CHUNK = 256  # entries per IPAddressAllow= argument (one is capped at 128 KiB)
TIMEOUT = 30  # seconds a systemctl call may take

CONTROL_DIRS = ("/run/systemd/system.control/", "/etc/systemd/system.control/")
# Drop-ins that aren't the unit's own configuration: runtime properties (ours
# included) and transient units.
NOT_STATIC = CONTROL_DIRS + ("/run/systemd/transient/",)


def is_glob(pattern):
    return any(c in pattern for c in "*?[")


def unique(items):
    out = []
    for i in items:
        if i not in out:
            out.append(i)
    return out


def missing_unit(stderr):
    return any(s in stderr for s in ("not loaded", "not found", "No such", "does not exist"))


class Allower:
    def __init__(self, cfg, now=time.time):
        self.systemctl = cfg["systemctl"]
        self.rules = cfg["rules"]
        self.local = Local(cfg.get("local") or [], cfg.get("localFile"))
        self.state = cfg.get("state")
        self.grants = cfg.get("grants")
        self.now = now
        # unit -> {address: {"name": the name it answered, "seen": time}}, for
        # every unit whose list this daemon has written.
        self.learned = {}
        self.dirty = False
        self.saved = 0

    def run(self, *args):
        try:
            return subprocess.run([self.systemctl, *args], capture_output=True, text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(args, 1, "", f"systemctl {args[0]} timed out")

    # ── which rules, units and entries ──

    @staticmethod
    def covers(rule, unit):
        return any(fnmatch.fnmatchcase(unit, p) if is_glob(p) else unit == p for p in rule["units"])

    def rules_for(self, unit):
        return [r for r in self.rules if self.covers(r, unit)]

    def static(self, unit):
        return unique(a for r in self.rules_for(unit) for a in r.get("allow") or [])

    def valid(self, unit, name, addr, nets):
        """Whether `name`'s answer `addr` may (still) be open to `unit`."""
        if Local.contains(nets, addr):
            return False
        return any(
            any(name_matches(name, p) for p in r["names"]) and not Local.contains(rule_deny(r), addr)
            for r in self.rules_for(unit)
        )

    def units(self, patterns, every=False):
        """The units `patterns` name: a glob, its active units (`every`: all
        loaded ones, and any with a runtime property drop-in)."""
        out = []
        for p in patterns:
            if not is_glob(p):
                out.append(p)
                continue
            state = "--all" if every else "--state=active"
            r = self.run("list-units", "--no-legend", "--plain", state, p)
            out += [l.split()[0] for l in r.stdout.splitlines() if l.strip() and fnmatch.fnmatchcase(l.split()[0], p)]
            if every:
                for d in CONTROL_DIRS:
                    try:
                        names = os.listdir(d)
                    except OSError:
                        continue
                    out += [n[:-2] for n in names if n.endswith(".d") and fnmatch.fnmatchcase(n[:-2], p)]
        return unique(out)

    def prune(self, entries):
        cutoff = self.now() - MAX_AGE
        kept = sorted(
            ((a, e) for a, e in entries.items() if e["seen"] >= cutoff),
            key=lambda ae: ae[1]["seen"],
            reverse=True,
        )[:MAX_PER_UNIT]
        return {a: e for a, e in sorted(kept, key=lambda ae: ae[1]["seen"])}

    # ── writing ──

    def granted(self, unit):
        """The broker's grants to `unit` (sbx-attach's record); call with the
        grants lock held."""
        if not self.grants:
            return []
        try:
            with open(os.path.join(self.grants, "grants.json")) as f:
                nets = json.load(f)["units"].get(unit) or []
            return [str(n) for n in nets if isinstance(n, str)]
        except FileNotFoundError:
            return []
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
            log(f"{self.grants}: {e}")
            return []

    def lock(self):
        """sbx-attach's grants lock (an fd to close), or None without one."""
        if not self.grants:
            return None
        try:
            fd = os.open(os.path.join(self.grants, "lock"), os.O_RDONLY | os.O_CLOEXEC)
        except FileNotFoundError:
            return None
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fd

    def set_allow(self, unit, entries):
        """Set `unit`'s whole IPAddressAllow= list, `entries` and the broker's
        grants, in one call (the reset first, all together: the filter is
        never briefly empty). Returns the error, None on success, or
        "missing" for a unit that isn't there."""
        fd = self.lock()
        try:
            entries = unique(list(entries) + self.granted(unit))
            args = ["set-property", "--runtime", unit, "IPAddressAllow="]
            args += ["IPAddressAllow=" + " ".join(entries[i : i + CHUNK]) for i in range(0, len(entries), CHUNK)]
            r = self.run(*args)
        finally:
            if fd is not None:
                os.close(fd)
        if r.returncode == 0:
            return None
        return "missing" if missing_unit(r.stderr) else (r.stderr.strip() or f"exit {r.returncode}")

    def apply(self, unit, entries):
        """Write `unit`'s static list plus `entries` (its learned addresses);
        on success they become its learned set. True on success."""
        entries = self.prune(entries)
        static = self.static(unit)
        err = self.set_allow(unit, static + [a for a in entries if a not in static])
        if err == "missing":
            self.learned.pop(unit, None)
            self.dirty = True
            return False
        if err:
            log(f"{unit}: {err}")
            return False
        self.learned[unit] = entries
        self.dirty = True
        return True

    def unit_file_allow(self, unit):
        """The IPAddressAllow= entries of `unit`'s own unit file and drop-ins
        (not runtime properties); None if they can't be read, False if the
        unit is gone."""
        r = self.run("show", "--property=LoadState,FragmentPath,DropInPaths", unit)
        if r.returncode != 0:
            return False if missing_unit(r.stderr) else None
        props = dict(l.split("=", 1) for l in r.stdout.splitlines() if "=" in l)
        if props.get("LoadState") == "not-found":
            return False
        if props.get("LoadState") != "loaded" or not props.get("FragmentPath"):
            return None
        paths = [props["FragmentPath"]] + (props.get("DropInPaths") or "").split()
        allow = []
        for path in paths:
            if path.startswith(NOT_STATIC):
                continue
            try:
                with open(path) as f:
                    lines = f.read().splitlines()
            except OSError as e:
                log(f"{unit}: {e}")
                return None
            for line in lines:
                key, sep, value = line.strip().partition("=")
                if not sep or key.strip() != "IPAddressAllow":
                    continue
                value = value.strip()
                if value:
                    allow += value.split()
                else:
                    allow = []
        return unique(allow)

    def startup(self):
        """Write every managed unit's current full list (replacing whatever a
        previous build left in its drop-in), with the learned addresses that
        are still allowed; put units no rule covers any more back to their
        unit files' list."""
        saved = self.load()
        nets = self.local.nets()
        if nets is None:  # sbx-netlocal's set unknown: check the static ranges only
            nets = self.local.static
        managed = unique(
            [u for r in self.rules for u in self.units(r["units"], every=True)]
            + [u for u in saved if self.rules_for(u)]
        )
        for unit in managed:
            entries = {
                a: e
                for a, e in saved.get(unit, {}).items()
                if self.valid(unit, e.get("name", ""), a, nets)
            }
            dropped = len(saved.get(unit, {})) - len(entries)
            if self.apply(unit, entries):
                log(
                    f"{unit}: {len(self.static(unit))} static, {len(self.learned[unit])} learned"
                    + (f" ({dropped} no longer allowed)" if dropped else "")
                )
        for unit in saved:
            if self.rules_for(unit):
                continue
            allow = self.unit_file_allow(unit)
            err = "missing" if allow is False else self.set_allow(unit, allow) if allow is not None else "unreadable"
            if err is None:
                log(f"{unit}: no longer managed; back to its unit files' {len(allow)} entries")
            elif err != "missing":
                # Kept (with nothing learned), to try again at the next start.
                self.learned[unit] = {}
                log(f"{unit}: no longer managed, and its unit files' list couldn't be set ({err}); left as is")
        self.save(force=True)

    # ── state ──

    def load(self):
        if not self.state:
            return {}
        try:
            with open(self.state) as f:
                units = json.load(f)["units"]
            return {
                u: {a: {"name": str(e["name"]), "seen": float(e["seen"])} for a, e in entries.items()}
                for u, entries in units.items()
            }
        except FileNotFoundError:
            return {}
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
            log(f"{self.state}: {e}; starting with no learned addresses")
            return {}

    def save(self, force=False):
        if not self.state or not (self.dirty or force):
            return
        if not force and self.now() - self.saved < SAVE_EVERY:
            return
        tmp = self.state + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump({"units": self.learned}, f)
            os.replace(tmp, self.state)
        except OSError as e:
            log(f"{self.state}: {e}")
            return
        self.dirty = False
        self.saved = self.now()

    # ── lookups ──

    def handle(self, params):
        names, addrs = result_names_and_addresses(params)
        if not names or not addrs:
            return
        rules = [r for r in self.rules if any(name_matches(n, p) for n in names for p in r["names"])]
        if not rules:
            return
        nets = self.local.nets()
        if nets is None:
            log(f"{', '.join(names)}: the host's local prefixes are unknown; opening nothing")
            return
        local = [a for a in addrs if Local.contains(nets, a)]
        if local:
            log(f"{', '.join(names)}: not opening local {' '.join(local)}")
            addrs = [a for a in addrs if a not in local]
        if not addrs:
            return
        now = self.now()
        changed = False
        for rule in rules:
            denied = [a for a in addrs if Local.contains(rule_deny(rule), a)]
            if denied:
                log(f"{', '.join(names)}: not opening {' '.join(denied)}, which {' '.join(rule['units'])} deny")
            allowed = [a for a in addrs if a not in denied]
            name = next(n for n in names if any(name_matches(n, p) for p in rule["names"]))
            for unit in self.units(rule["units"]):
                old = self.learned.get(unit, {})
                new = [a for a in allowed if a not in old]
                for a in allowed:
                    if a in old:
                        old[a]["seen"] = now
                        self.dirty = True
                if not new:
                    continue
                entries = dict(old)
                entries.update((a, {"name": norm(name), "seen": now}) for a in new)
                if self.apply(unit, entries):
                    changed = True
                    if new:
                        log(f"{unit}: {', '.join(names)} -> {' '.join(new)}")
        self.save(force=changed)


def subscribe(allower):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    s.connect(MONITOR)
    req = {"method": "io.systemd.Resolve.Monitor.SubscribeQueryResults", "parameters": {}, "more": True}
    s.sendall(json.dumps(req).encode() + b"\0")
    log("subscribed to resolved's query monitor")
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            raise ConnectionError("resolved closed the monitor connection")
        buf += chunk
        while b"\0" in buf:
            raw, buf = buf.split(b"\0", 1)
            msg = json.loads(raw)
            if "error" in msg:
                raise ConnectionError(f"monitor: {msg['error']}")
            params = msg.get("parameters") or {}
            try:
                allower.handle(params)
            except Exception as e:  # one bad result mustn't end the subscription
                log(f"{type(e).__name__}: {e}")


def main():
    with open(sys.argv[-1]) as f:
        cfg = json.load(f)
    if sys.argv[1:2] == ["--cleanup"]:
        cfg["rules"] = []
    allower = Allower(cfg)
    allower.startup()
    if sys.argv[1:2] == ["--cleanup"] or not allower.rules:
        return
    delay = 1
    while True:
        started = time.monotonic()
        try:
            subscribe(allower)
        except (OSError, ConnectionError, ValueError) as e:
            if time.monotonic() - started > 60:
                delay = 1
            log(f"{e}; reconnecting in {delay}s")
            time.sleep(delay)
            delay = min(delay * 2, 30)



# ── sbx-netlocal ──────────────────────────────────────────────────────────────

RESCAN = 30  # seconds between full rescans without any netlink event
SETTLE = 0.2  # quiet time that ends a burst of events
SETTLE_MAX = 2  # ... or this long after it began, if it doesn't end


def notify(msg):
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM | socket.SOCK_CLOEXEC) as s:
        s.connect(addr)
        s.sendall(msg.encode())


def network(text):
    try:
        return ipaddress.ip_network(text, strict=False)
    except ValueError:
        return None


class Tracker:
    def __init__(self, cfg):
        self.ip = cfg["ip"]
        self.systemctl = cfg["systemctl"]
        self.slice = cfg["slice"]
        self.state = cfg["state"]
        self.static = [ipaddress.ip_network(c) for c in cfg["static"]]
        self.min = {4: cfg["minPrefix4"], 6: cfg["minPrefix6"]}
        self.widen6 = cfg.get("widen6")
        self.applied = None  # the list last set on the slice

    def ipj(self, *args):
        r = subprocess.run([self.ip, "-j", *args], capture_output=True, text=True, check=True)
        return json.loads(r.stdout or "[]")

    def keep(self, net, lan):
        if net is None or net.prefixlen < self.min[net.version]:
            return None
        if any(net.version == s.version and net.subnet_of(s) for s in self.static):
            return None
        if net.version == 6 and lan and self.widen6 and net.prefixlen > self.widen6:
            net = net.supernet(new_prefix=self.widen6)
        return net

    def current(self):
        """The host's and LAN's public prefixes, collapsed and sorted."""
        lan = set()
        for link in self.ipj("link", "show"):
            flags = link.get("flags") or []
            if "BROADCAST" in flags and "POINTOPOINT" not in flags:
                lan.add(link.get("ifname"))
        found = []

        def add(text, on_lan):
            net = self.keep(network(text), on_lan)
            if net is not None:
                found.append(net)

        for iface in self.ipj("addr", "show"):
            on_lan = iface.get("ifname") in lan
            for a in iface.get("addr_info") or []:
                for key in ("local", "address"):  # "address": a point-to-point peer
                    if a.get(key):
                        add(a[key], on_lan)
                if on_lan and a.get("local") and a.get("prefixlen") is not None:
                    add(f"{a['local']}/{a['prefixlen']}", True)
        for family in ("-4", "-6"):
            for r in self.ipj(family, "route", "show", "table", "all"):
                if r.get("dev") not in lan:
                    continue
                if r.get("type", "unicast") not in ("unicast", "local", "anycast", "broadcast"):
                    continue
                dst = r.get("dst")
                if not dst or dst == "default":
                    continue
                routed = any(k in r for k in ("gateway", "via", "nexthops", "nhid"))
                if routed and r.get("protocol") != "ra":
                    continue
                add(dst, True)
        out = []
        for v in (4, 6):
            out += ipaddress.collapse_addresses(n for n in found if n.version == v)
        return out

    def publish(self, nets):
        tmp = self.state + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"prefixes": [str(n) for n in nets]}, f)
        os.chmod(tmp, 0o644)
        os.replace(tmp, self.state)

    def refresh(self):
        nets = self.current()
        if nets == self.applied:
            return
        # The state first: sbx-dnsallow must never check against a stale set.
        self.publish(nets)
        args = [self.systemctl, "set-property", "--runtime", self.slice, "IPAddressDeny="]
        if nets:
            args.append("IPAddressDeny=" + " ".join(str(n) for n in nets))
        r = subprocess.run(args, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"set-property {self.slice}: {r.stderr.strip()}")
        self.applied = nets
        log(f"{self.slice}: deny {' '.join(str(n) for n in nets) or '(nothing)'}")


def watch(tracker, ready):
    # The monitor starts before the scan, so a change between the two still
    # triggers another (and the rescan catches one the monitor missed).
    mon = subprocess.Popen(
        [tracker.ip, "monitor", "link", "address", "route"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    fd = mon.stdout.fileno()
    try:
        while True:
            try:
                tracker.refresh()
                if not ready:
                    notify("READY=1")
                    ready = True
            except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as e:
                # Keep whatever was set last (or the slice's fail-closed default).
                log(f"{type(e).__name__}: {e}")
            readable, _, _ = select.select([fd], [], [], RESCAN)
            burst = time.monotonic()
            while readable:
                if not os.read(fd, 65536):
                    raise ConnectionError("ip monitor exited")
                if time.monotonic() - burst > SETTLE_MAX:
                    break
                readable, _, _ = select.select([fd], [], [], SETTLE)
    finally:
        mon.kill()
        mon.wait()


def netlocal_main():
    dry = sys.argv[1:2] == ["--dry-run"]
    with open(sys.argv[-1]) as f:
        tracker = Tracker(json.load(f))
    if dry:
        print("\n".join(str(n) for n in tracker.current()))
        return
    ready = False
    while True:
        try:
            watch(tracker, ready)
        except (OSError, ConnectionError) as e:
            log(f"{e}; restarting the monitor")
        ready = tracker.applied is not None
        time.sleep(1)


if __name__ == "__main__":
    netlocal_main() if PROG == "sbx-netlocal" else main()
