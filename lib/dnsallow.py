"""sbx-dnsallow and sbx-netlocal: the sandboxes' network policy at run time.

One file, two root daemons (one each per host), told apart by the name they
run under; modules/system/sandbox-dnsallow.nix runs both.

sbx-dnsallow: open a sandbox's IP filter to the addresses its allowed names
resolve to. Subscribes to systemd-resolved's query monitor
(io.systemd.Resolve.Monitor.SubscribeQueryResults, varlink) and, whenever a
lookup of a name some sandbox may reach succeeds, adds the answer's A/AAAA
addresses to that sandbox's units:

    systemctl set-property --runtime UNIT IPAddressAllow=ADDR...

Names: "example.com" (exactly), "*.example.com" (any name under it, not the
name itself). The query that matched may have been made by anyone on the host:
that only ever opens addresses of names the sandbox was allowed anyway. The
additions last until reboot (runtime drop-ins), across restarts of the unit.

An allowed name never opens a local address: IPAddressAllow= wins over every
deny (the static ranges and the slice's), so answers in `local` (netpolicy's
static ranges) or in sbx-netlocal's current set of the host's and LAN's public
prefixes (`localFile`) are dropped. While localFile is configured but missing
(sbx-netlocal isn't running), nothing is opened.

Config (JSON): {"systemctl": PATH, "local": [CIDR...], "localFile": PATH or
null, "rules": [{"units": [UNIT or GLOB...], "names": [NAME...]}]}

sbx-netlocal: keep the sandboxes in a restricted network mode off the host's
and LAN's public addresses. netpolicy's static ranges (RFC 1918, ULA, ...)
can't name the host's own global addresses or its LAN's global prefixes: on an
IPv6 LAN the router hands those out, and they change. This one watches the kernel's
addresses and routes (`ip monitor`, plus a rescan every RESCAN seconds) and
keeps the sandboxes' slice denied them:

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


class Allower:
    def __init__(self, cfg):
        self.systemctl = cfg["systemctl"]
        self.rules = cfg["rules"]
        self.local = Local(cfg.get("local") or [], cfg.get("localFile"))
        self.done = set()  # (unit, address)

    def units(self, patterns):
        out = []
        for p in patterns:
            if any(c in p for c in "*?["):
                r = subprocess.run(
                    [self.systemctl, "list-units", "--no-legend", "--plain", "--state=active", p],
                    capture_output=True,
                    text=True,
                )
                out += [l.split()[0] for l in r.stdout.splitlines() if l.strip() and fnmatch.fnmatch(l.split()[0], p)]
            else:
                out.append(p)
        return out

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
        for rule in rules:
            for unit in self.units(rule["units"]):
                new = [a for a in addrs if (unit, a) not in self.done]
                if not new:
                    continue
                r = subprocess.run(
                    [self.systemctl, "set-property", "--runtime", unit, "IPAddressAllow=" + " ".join(new)],
                    capture_output=True,
                    text=True,
                )
                if r.returncode == 0:
                    if len(self.done) > 100000:
                        self.done.clear()
                    self.done.update((unit, a) for a in new)
                    log(f"{unit}: {', '.join(names)} -> {' '.join(new)}")
                elif "not loaded" not in r.stderr:
                    log(f"{unit}: {r.stderr.strip()}")


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
    with open(sys.argv[1]) as f:
        allower = Allower(json.load(f))
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
