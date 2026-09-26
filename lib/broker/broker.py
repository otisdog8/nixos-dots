"""sbx-broker: controlled escapes and temporary grants for sandboxes.

Runs as the user, in the user's session. Every sandbox reaches it on its OWN
unix socket ($XDG_RUNTIME_DIR/sbx-broker/<sandbox>.sock: bound into containers,
relayed into VMs), so which socket a request arrives on IS the requester's
identity; nothing a sandbox sends can change it.

Protocol: one JSON request per connection (a single line), answered by a stream
of JSON lines, the last one final:
  {"op": "exec", "as": "user"|"root", "argv": [...], "cwd": "/path"?, "reason": "..."?}
      → {"type": "stdout"|"stderr", "data": <base64>}* then {"type": "exit", "code": N}
  {"op": "grant-net", "addr": "IP or CIDR", "reason": "..."?}
      → {"type": "granted"}
  {"op": "grant-path", "path": "/abs/path", "write": bool, "reason": "..."?}
      → {"type": "granted"}
  {"op": "camera", "reason": "..."?}
      → {"type": "granted"} once the host's camera(s) are attached to the
        sandbox (VMs: USB passthrough, until the VM stops)
  {"op": "fido"}
      → {"type": "granted"}, then the connection carries raw 64-byte CTAPHID
        reports both ways to the security key plugged in now (VMs: their guest
        has a virtual FIDO device, lib/vm/fido-guest.py). Only the CTAPHID
        channels the sandbox opened itself are relayed, so it never sees the
        host's own traffic with the key.
  any refusal → {"type": "denied", "reason": "..."}; bad input → {"type": "error", ...}

Every request not covered by a rule asks the user with sbx-prompt (a desktop
dialog naming the sandbox, what it wants, and the sandbox's stated reason,
labelled as such). Rules come from the Nix config (modules.sandbox.broker).
"""

import base64
import ipaddress
import json
import os
import select
import shlex
import socket
import stat
import subprocess
import sys
import threading
import time

MAX_REQUEST = 64 * 1024
MAX_ARGS = 256
SESSION_TTL = 12 * 3600


def log(msg):
    print(f"sbx-broker: {msg}", file=sys.stderr, flush=True)


class Broker:
    def __init__(self, config):
        self.cfg = config
        self.prompt = config["prompt"]
        self.run0 = config["run0"]
        self.systemctl = config["systemctl"]
        self.sandboxes = config["sandboxes"]
        self.approved = {}  # (sandbox, key) -> expiry
        self.lock = threading.Lock()

    # ── Decisions ────────────────────────────────────────────────────────────
    def rule_for(self, sandbox, op, as_, argv):
        for r in self.sandboxes[sandbox].get("rules", []):
            if r.get("op", "exec") != op:
                continue
            if op == "exec":
                if r.get("as", "user") != as_:
                    continue
                pat = r.get("argv", [])
                if r.get("match", "prefix") == "exact":
                    if argv != pat:
                        continue
                elif argv[: len(pat)] != pat:
                    continue
            return r.get("action", "prompt")
        return None

    def decide(self, sandbox, op, key, summary, detail, as_="user", argv=None, allow_session=True):
        action = self.rule_for(sandbox, op, as_, argv or [])
        if action == "deny":
            return False, "denied by rule"
        if action == "allow":
            return True, "allowed by rule"
        now = time.time()
        with self.lock:
            exp = self.approved.get((sandbox, key))
            if exp and exp > now:
                return True, "allowed earlier this session"
        args = [self.prompt, "--timeout", "90"]
        if not allow_session:
            args.append("--no-session")
        args += ["--", self.sandboxes[sandbox]["label"], summary, detail]
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=120)
            answer = r.stdout.strip()
        except (OSError, subprocess.TimeoutExpired) as e:
            log(f"prompt failed: {e}")
            return False, "could not ask the user"
        if answer == "session":
            with self.lock:
                self.approved[(sandbox, key)] = now + SESSION_TTL
            return True, "allowed for the session"
        if answer == "once":
            return True, "allowed once"
        return False, "denied by the user"

    # ── Operations ───────────────────────────────────────────────────────────
    def op_exec(self, sandbox, req, send):
        argv = req.get("argv")
        as_ = req.get("as", "user")
        if (
            not isinstance(argv, list)
            or not argv
            or len(argv) > MAX_ARGS
            or not all(isinstance(a, str) and "\0" not in a for a in argv)
        ):
            return send({"type": "error", "message": "argv must be a non-empty list of strings"})
        if as_ not in ("user", "root"):
            return send({"type": "error", "message": "as must be user or root"})
        cwd = req.get("cwd") or os.environ.get("HOME", "/")
        if not isinstance(cwd, str) or not os.path.isabs(cwd) or not os.path.isdir(cwd):
            cwd = os.environ.get("HOME", "/")
        reason = str(req.get("reason", ""))[:500]
        cmd = shlex.join(argv)
        who = "ROOT" if as_ == "root" else "your user"
        summary = f"run a command outside its sandbox as {who}:\n{cmd}"
        detail = f"in {cwd}"
        if reason:
            detail += f"\n\nThe sandbox says why (unverified): {reason}"
        ok, why = self.decide(
            sandbox,
            "exec",
            ("exec", as_, tuple(argv)),
            summary,
            detail,
            as_=as_,
            argv=argv,
            # A root command is never approved for the rest of the session.
            allow_session=(as_ == "user"),
        )
        log(f"{sandbox}: exec as {as_}: {cmd} in {cwd}: {why}")
        if not ok:
            return send({"type": "denied", "reason": why})
        full = argv if as_ == "user" else [self.run0, "--user=root", "--", *argv]
        try:
            p = subprocess.Popen(
                full, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
        except OSError as e:
            return send({"type": "error", "message": f"could not run {argv[0]}: {e.strerror}"})

        def pump(stream, kind):
            for chunk in iter(lambda: stream.read1(65536), b""):
                send({"type": kind, "data": base64.b64encode(chunk).decode()})

        t = threading.Thread(target=pump, args=(p.stderr, "stderr"), daemon=True)
        t.start()
        pump(p.stdout, "stdout")
        t.join()
        send({"type": "exit", "code": p.wait()})

    def op_grant_net(self, sandbox, req, send):
        addr = req.get("addr")
        try:
            net = ipaddress.ip_network(str(addr), strict=False)
        except ValueError:
            return send({"type": "error", "message": "addr must be an IP address or prefix"})
        units = self.sandboxes[sandbox].get("netUnits", [])
        if not units:
            return send({"type": "denied", "reason": "this sandbox's network isn't filtered per sandbox"})
        reason = str(req.get("reason", ""))[:500]
        detail = "until the sandbox stops"
        if reason:
            detail += f"\n\nThe sandbox says why (unverified): {reason}"
        ok, why = self.decide(sandbox, "grant-net", ("net", str(net)), f"connect to {net}", detail)
        log(f"{sandbox}: grant-net {net}: {why}")
        if not ok:
            return send({"type": "denied", "reason": why})
        running = self.running_units(units)
        if not running:
            return send({"type": "denied", "reason": "the sandbox isn't running"})
        for u in running:
            r = subprocess.run(
                [self.systemctl, "set-property", "--runtime", u, f"IPAddressAllow={net}"],
                capture_output=True,
                text=True,
            )
            if r.returncode != 0:
                log(f"set-property {u}: {r.stderr.strip()}")
                return send({"type": "error", "message": f"could not update {u}"})
        send({"type": "granted"})

    def op_grant_path(self, sandbox, req, send):
        path = req.get("path")
        write = bool(req.get("write", False))
        if not isinstance(path, str) or not os.path.isabs(path) or "\0" in path or "\n" in path:
            return send({"type": "error", "message": "path must be absolute"})
        path = os.path.realpath(path)
        grant = self.sandboxes[sandbox].get("grantPaths")
        if not grant:
            return send({"type": "denied", "reason": "this sandbox can't take new folders while running"})
        home = os.environ.get("HOME", "/nonexistent")
        if not path.startswith(home + "/"):
            return send({"type": "denied", "reason": "only folders inside your home can be granted"})
        try:
            st = os.stat(path)
        except OSError:
            return send({"type": "error", "message": "no such folder"})
        if not stat.S_ISDIR(st.st_mode):
            return send({"type": "error", "message": "not a folder"})
        reason = str(req.get("reason", ""))[:500]
        mode = "read and change" if write else "read"
        detail = "until the sandbox stops"
        if reason:
            detail += f"\n\nThe sandbox says why (unverified): {reason}"
        ok, why = self.decide(sandbox, "grant-path", ("path", path, write), f"{mode} {path}", detail)
        log(f"{sandbox}: grant-path {path} write={write}: {why}")
        if not ok:
            return send({"type": "denied", "reason": why})
        r = subprocess.run([grant, path, "rw" if write else "ro"], capture_output=True, text=True)
        if r.returncode != 0:
            log(f"grant {path}: {r.stderr.strip()}")
            return send({"type": "error", "message": r.stderr.strip() or "could not grant the folder"})
        send({"type": "granted"})

    def op_camera(self, sandbox, req, send):
        prog = self.sandboxes[sandbox].get("camera")
        if not prog:
            return send({"type": "denied", "reason": "this sandbox has no camera access"})
        reason = str(req.get("reason", ""))[:500]
        detail = "until the sandbox stops; meanwhile no other app can use the camera"
        if reason:
            detail += f"\n\nThe sandbox says why (unverified): {reason}"
        ok, why = self.decide(sandbox, "camera", ("camera",), "use your camera", detail)
        log(f"{sandbox}: camera: {why}")
        if not ok:
            return send({"type": "denied", "reason": why})
        r = subprocess.run([prog, "attach"], capture_output=True, text=True)
        if r.returncode != 0:
            log(f"{sandbox}: camera: {r.stderr.strip()}")
            return send({"type": "error", "message": r.stderr.strip() or "could not attach the camera"})
        send({"type": "granted"})

    def op_fido(self, sandbox, req, send, conn):
        if not self.sandboxes[sandbox].get("fido"):
            return send({"type": "denied", "reason": "this sandbox has no security key access"})
        node = find_fido_token()
        if node is None:
            return send({"type": "error", "message": "no security key is plugged in"})
        ok, why = self.decide(
            sandbox,
            "fido",
            ("fido",),
            "use your security key (FIDO/WebAuthn)",
            "until the sandbox stops; each sign-in still needs a touch on the key",
        )
        log(f"{sandbox}: fido {node}: {why}")
        if not ok:
            return send({"type": "denied", "reason": why})
        try:
            fd = os.open(node, os.O_RDWR | os.O_CLOEXEC)
        except OSError as e:
            return send({"type": "error", "message": f"could not open the security key: {e.strerror}"})
        send({"type": "granted"})
        try:
            CtapRelay(fd, conn).run()
        finally:
            os.close(fd)

    def running_units(self, units):
        out = []
        for pattern in units:
            r = subprocess.run(
                [self.systemctl, "list-units", "--no-legend", "--plain", "--state=active", pattern],
                capture_output=True,
                text=True,
            )
            out += [line.split()[0] for line in r.stdout.splitlines() if line.strip()]
        return out

    # ── Serving ──────────────────────────────────────────────────────────────
    def handle(self, sandbox, conn):
        wlock = threading.Lock()

        def send(msg):
            data = (json.dumps(msg) + "\n").encode()
            with wlock:
                try:
                    conn.sendall(data)
                except OSError:
                    pass

        try:
            conn.settimeout(30)
            buf = b""
            while b"\n" not in buf:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
                if len(buf) > MAX_REQUEST:
                    return send({"type": "error", "message": "request too large"})
            conn.settimeout(None)
            try:
                req = json.loads(buf.split(b"\n", 1)[0])
                if not isinstance(req, dict):
                    raise ValueError
            except ValueError:
                return send({"type": "error", "message": "bad request"})
            op = req.get("op")
            fn = {
                "exec": self.op_exec,
                "grant-net": self.op_grant_net,
                "grant-path": self.op_grant_path,
                "camera": self.op_camera,
                "fido": lambda sb, r, snd: self.op_fido(sb, r, snd, conn),
            }.get(op)
            if fn is None:
                return send({"type": "error", "message": f"unknown op {op!r}"})
            fn(sandbox, req, send)
        except Exception as e:  # never let one request take the broker down
            log(f"{sandbox}: {type(e).__name__}: {e}")
            send({"type": "error", "message": "internal error"})
        finally:
            conn.close()

    def bind(self, path, extra_uid):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
        s.bind(path)
        os.chmod(path, 0o600)
        if extra_uid is not None:
            # A dedicated-uid sandbox connects as its own uid.
            subprocess.run([self.cfg["setfacl"], "-m", f"u:{extra_uid}:rw", path], check=True)
        s.listen(16)
        return s

    def serve(self, sandbox, s):
        while True:
            conn, _ = s.accept()
            threading.Thread(target=self.handle, args=(sandbox, conn), daemon=True).start()


# ── FIDO ─────────────────────────────────────────────────────────────────────
FIDO_USAGE_PAGE = bytes([0x06, 0xD0, 0xF1])  # Usage Page (FIDO Alliance)
CTAP_REPORT = 64
CTAP_BROADCAST = b"\xff\xff\xff\xff"
CTAP_INIT = 0x86  # CTAPHID_INIT with the initialization-packet bit


def find_fido_token():
    """The first hidraw node whose report descriptor declares the FIDO usage page."""
    base = "/sys/class/hidraw"
    try:
        names = sorted(os.listdir(base), key=lambda n: int(n[6:]) if n[6:].isdigit() else 0)
    except OSError:
        return None
    for name in names:
        try:
            with open(os.path.join(base, name, "device", "report_descriptor"), "rb") as f:
                if FIDO_USAGE_PAGE in f.read():
                    return f"/dev/{name}"
        except OSError:
            continue
    return None


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


class CtapRelay:
    """Pump CTAPHID reports between a sandbox and a hidraw key.

    hidraw hands every input report to every process that has the key open, so
    responses to the host's own clients would reach the sandbox too. Only
    channels the sandbox allocated (CTAPHID_INIT on the broadcast channel,
    matched by its nonce) are relayed back; the sandbox may only send on those
    channels (or allocate new ones)."""

    def __init__(self, fd, conn):
        self.fd = fd
        self.conn = conn
        self.cids = set()
        self.nonces = set()
        self.lock = threading.Lock()
        self.done = threading.Event()

    def run(self):
        t = threading.Thread(target=self.from_key, daemon=True)
        t.start()
        try:
            while not self.done.is_set():
                pkt = recv_exact(self.conn, CTAP_REPORT)
                if pkt is None:
                    break
                cid = pkt[:4]
                with self.lock:
                    if cid == CTAP_BROADCAST:
                        if pkt[4] != CTAP_INIT:
                            continue
                        self.nonces.add(pkt[7:15])
                        if len(self.nonces) > 64:
                            self.nonces.pop()
                    elif cid not in self.cids:
                        continue
                os.write(self.fd, b"\0" + pkt)
        except OSError:
            pass
        finally:
            self.done.set()
            t.join(2)

    def from_key(self):
        poll = select.poll()
        poll.register(self.fd, select.POLLIN)
        try:
            while not self.done.is_set():
                if not poll.poll(500):
                    continue
                pkt = os.read(self.fd, CTAP_REPORT)
                if len(pkt) < CTAP_REPORT:
                    pkt = pkt.ljust(CTAP_REPORT, b"\0")
                cid = pkt[:4]
                with self.lock:
                    if cid == CTAP_BROADCAST and pkt[4] == CTAP_INIT and pkt[7:15] in self.nonces:
                        self.nonces.discard(pkt[7:15])
                        self.cids.add(pkt[15:19])
                    elif cid not in self.cids:
                        continue
                self.conn.sendall(pkt)
        except OSError:
            pass  # the key was unplugged, or the sandbox went away
        finally:
            self.done.set()
            try:
                self.conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def main():
    config_path = sys.argv[1]
    with open(config_path) as f:
        config = json.load(f)
    rundir = os.path.join(os.environ["XDG_RUNTIME_DIR"], "sbx-broker")
    os.makedirs(rundir, mode=0o711, exist_ok=True)
    os.chmod(rundir, 0o711)
    broker = Broker(config)
    # Bind every socket before serving any, so a failure stops the broker (and
    # systemd restarts it) instead of leaving a sandbox silently without one.
    sockets = {
        name: broker.bind(os.path.join(rundir, f"{name}.sock"), sb.get("uid"))
        for name, sb in config["sandboxes"].items()
    }
    threads = []
    for name, s in sockets.items():
        t = threading.Thread(target=broker.serve, args=(name, s), daemon=True)
        t.start()
        threads.append(t)
    log(f"serving {len(threads)} sandboxes")
    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
