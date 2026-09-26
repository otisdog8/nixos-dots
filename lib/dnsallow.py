"""sbx-dnsallow: open a sandbox's IP filter to the addresses its allowed names resolve to.

Root, one per host. Subscribes to systemd-resolved's query monitor
(io.systemd.Resolve.Monitor.SubscribeQueryResults, varlink) and, whenever a
lookup of a name some sandbox may reach succeeds, adds the answer's A/AAAA
addresses to that sandbox's units:

    systemctl set-property --runtime UNIT IPAddressAllow=ADDR...

Names: "example.com" (exactly), "*.example.com" (any name under it, not the
name itself). The query that matched may have been made by anyone on the host:
that only ever opens addresses of names the sandbox was allowed anyway. The
additions last until reboot (runtime drop-ins), across restarts of the unit.

Config (JSON): {"systemctl": PATH, "rules": [{"units": [UNIT or GLOB...],
"names": [NAME...]}]}
"""

import fnmatch
import ipaddress
import json
import socket
import subprocess
import sys
import time

MONITOR = "/run/systemd/resolve/io.systemd.Resolve.Monitor"
A, AAAA = 1, 28


def log(msg):
    print(f"sbx-dnsallow: {msg}", file=sys.stderr, flush=True)


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


class Allower:
    def __init__(self, cfg):
        self.systemctl = cfg["systemctl"]
        self.rules = cfg["rules"]
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
        for rule in self.rules:
            if not any(name_matches(n, p) for n in names for p in rule["names"]):
                continue
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


if __name__ == "__main__":
    main()
