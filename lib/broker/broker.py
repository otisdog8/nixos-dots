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
  {"op": "authenticate", "action": "<the sandbox's polkit action id>"}
      → {"type": "granted"} once the USER has authenticated on the host (their
        own polkit agent: password, fingerprint, whatever PAM's polkit-1 asks)
        for the host action the config maps that sandbox action to. The
        sandbox's polkit agent (lib/vm/polkit-agent.py) then completes its own
        authorization: "system authentication" for apps in a VM, whose guest
        user has no password. No dialog of ours: the host agent's is the prompt.
  any refusal → {"type": "denied", "reason": "..."}; bad input → {"type": "error", ...}

Audio: a sandbox with audio also gets $XDG_RUNTIME_DIR/sbx-broker/<sandbox>.pulse,
a PulseAudio socket in front of the user's own (PulseFilter below): playback
passes, recording (the microphone, or a monitor of what other apps play) needs
the sandbox's microphone capability and the user's approval, and whatever
reconfigures the sound server for everyone is refused.

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
import struct
import socket
import stat
import subprocess
import sys
import threading
import time

MAX_REQUEST = 64 * 1024
MAX_ARGS = 256
SESSION_TTL = 12 * 3600
# authenticate: one at a time per sandbox; after AUTH_FAILS failed or dismissed
# authentications in a row, refuse for AUTH_PAUSE seconds (a compromised
# sandbox can't keep the user's password dialog on screen).
AUTH_FAILS = 3
AUTH_PAUSE = 300
AUTH_TIMEOUT = 300


def log(msg):
    print(f"sbx-broker: {msg}", file=sys.stderr, flush=True)


class Broker:
    def __init__(self, config):
        self.cfg = config
        self.prompt = config["prompt"]
        self.run0 = config["run0"]
        self.systemctl = config["systemctl"]
        self.sandboxes = config["sandboxes"]
        self.pkcheck = config.get("pkcheck")
        self.approved = {}  # (sandbox, key) -> expiry
        self.lock = threading.Lock()
        self.auth_busy = set()  # sandboxes with an authentication on screen
        self.auth_fails = {}  # sandbox -> (failures in a row, paused until)

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

    def op_authenticate(self, sandbox, req, send, conn):
        action = req.get("action")
        mapping = self.sandboxes[sandbox].get("authenticate") or {}
        host_action = mapping.get(action) if isinstance(action, str) else None
        if not host_action or not self.pkcheck:
            log(f"{sandbox}: authenticate {str(action)[:100]!r}: not allowed for this sandbox")
            return send({"type": "denied", "reason": "this sandbox can't ask for system authentication for that"})
        now = time.time()
        with self.lock:
            fails, until = self.auth_fails.get(sandbox, (0, 0.0))
            if now < until:
                return send({"type": "denied", "reason": "paused after repeated failed authentications"})
            if sandbox in self.auth_busy:
                return send({"type": "denied", "reason": "an authentication for this sandbox is already on screen"})
            self.auth_busy.add(sandbox)
        try:
            ok, why = self.run_pkcheck(host_action, conn)
        finally:
            with self.lock:
                self.auth_busy.discard(sandbox)
        with self.lock:
            if ok:
                self.auth_fails.pop(sandbox, None)
            elif fails + 1 >= AUTH_FAILS:
                self.auth_fails[sandbox] = (0, time.time() + AUTH_PAUSE)
            else:
                self.auth_fails[sandbox] = (fails + 1, 0.0)
        log(f"{sandbox}: authenticate {action} (as {host_action}): {why}")
        send({"type": "granted"} if ok else {"type": "denied", "reason": why})

    def run_pkcheck(self, action, conn):
        """Authenticate the user for `action` through their own polkit agent.
        The subject is this broker (a process of the user's, whose session
        polkit finds through the user's graphical session), so the agent the
        user already trusts shows the dialog. Gives up when the requester
        disconnects (its own authentication was cancelled) or after
        AUTH_TIMEOUT."""
        try:
            with open("/proc/self/stat", encoding="ascii") as f:
                start = f.read().rsplit(")", 1)[1].split()[19]
        except (OSError, IndexError):
            return False, "could not identify the broker process"
        subject = f"{os.getpid()},{start},{os.getuid()}"
        try:
            p = subprocess.Popen(
                [self.pkcheck, "--action-id", action, "--process", subject, "--allow-user-interaction"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
        except OSError as e:
            return False, f"could not run pkcheck: {e.strerror}"
        deadline = time.monotonic() + AUTH_TIMEOUT
        while True:
            try:
                rc = p.wait(timeout=0.5)
                break
            except subprocess.TimeoutExpired:
                pass
            if time.monotonic() > deadline or peer_gone(conn):
                p.kill()
                p.wait()
                return False, "cancelled" if time.monotonic() <= deadline else "timed out"
        err = p.stderr.read().decode("utf-8", "replace").strip()[:300]
        p.stderr.close()
        if rc == 0:
            return True, "authenticated"
        # pkcheck: 1 not authorized, 2 still a challenge (no agent), 3 dismissed.
        return False, {1: "not authorized", 2: "no authentication agent", 3: "dismissed"}.get(
            rc, f"pkcheck exited {rc}: {err}"
        )

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
                "authenticate": lambda sb, r, snd: self.op_authenticate(sb, r, snd, conn),
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

    def serve_pulse(self, sandbox, s):
        upstream = os.path.join(os.environ["XDG_RUNTIME_DIR"], "pulse", "native")
        while True:
            conn, _ = s.accept()

            def run(conn=conn):
                try:
                    PulseFilter(self, sandbox, conn, upstream).run()
                except OSError as e:
                    log(f"{sandbox}: audio: {e}")
                    conn.close()

            threading.Thread(target=run, daemon=True).start()

    def serve(self, sandbox, s):
        while True:
            conn, _ = s.accept()
            threading.Thread(target=self.handle, args=(sandbox, conn), daemon=True).start()


# ── Audio ────────────────────────────────────────────────────────────────────
# PulseAudio's native protocol (pulsecore/native-common.h, pstream.c): packets of
# a 20-byte descriptor (length, channel, offset hi/lo, flags; big-endian u32s)
# and a payload. Channel 0xffffffff is a control packet, a tagstruct starting
# with the command and its tag (both 'L' u32s); any other channel is audio.
PA_DESC = struct.Struct("!IIIII")
PA_CONTROL = 0xFFFFFFFF
PA_MAX_PACKET = 16 * 1024 * 1024
PA_ERROR, PA_REPLY, PA_CREATE_RECORD_STREAM, PA_AUTH = 0, 2, 5, 8
PA_ERR_ACCESS = 1
# Shared memory can't cross the filter (it forwards no descriptors), so it is
# negotiated away in both directions of AUTH (PA_PROTOCOL_FLAG_SHM, _MEMFD).
PA_PROTOCOL_SHM_FLAGS = 0x80000000 | 0x40000000
# Commands that act on the server or on other clients rather than on the
# client's own streams: refused for every sandbox.
PA_REFUSED = {
    7: "EXIT",
    36: "SET_SINK_VOLUME",
    38: "SET_SOURCE_VOLUME",
    39: "SET_SINK_MUTE",
    40: "SET_SOURCE_MUTE",
    44: "SET_DEFAULT_SINK",
    45: "SET_DEFAULT_SOURCE",
    48: "KILL_CLIENT",
    49: "KILL_SINK_INPUT",
    50: "KILL_SOURCE_OUTPUT",
    51: "LOAD_MODULE",
    52: "UNLOAD_MODULE",
    53: "ADD_AUTOLOAD",
    54: "REMOVE_AUTOLOAD",
    67: "MOVE_SINK_INPUT",
    68: "MOVE_SOURCE_OUTPUT",
    70: "SUSPEND_SINK",
    71: "SUSPEND_SOURCE",
    87: "EXTENSION",
    90: "SET_CARD_PROFILE",
    96: "SET_SINK_PORT",
    97: "SET_SOURCE_PORT",
    100: "SET_PORT_LATENCY_OFFSET",
    104: "SEND_OBJECT_MESSAGE",
}


def pa_read_packet(sock):
    """(descriptor tuple, payload), or None at EOF. Descriptors (SCM_RIGHTS)
    are never taken: the kernel closes any that were sent."""
    head = recv_exact(sock, PA_DESC.size)
    if head is None:
        return None
    desc = PA_DESC.unpack(head)
    if desc[0] > PA_MAX_PACKET:
        raise ValueError("packet too large")
    payload = recv_exact(sock, desc[0]) if desc[0] else b""
    if payload is None:
        return None
    return desc, payload


def pa_command(payload):
    """(command, tag) of a control packet's tagstruct, or None."""
    if len(payload) >= 10 and payload[0:1] == b"L" and payload[5:6] == b"L":
        return struct.unpack("!I", payload[1:5])[0], struct.unpack("!I", payload[6:10])[0]
    return None


def pa_packet(payload):
    return PA_DESC.pack(len(payload), PA_CONTROL, 0, 0, 0) + payload


def pa_error(tag, error=PA_ERR_ACCESS):
    return pa_packet(b"L" + struct.pack("!I", PA_ERROR) + b"L" + struct.pack("!I", tag) + b"L" + struct.pack("!I", error))


def pa_clear_shm(payload, offset):
    """Clear the shm/memfd flag bits of the 'L' u32 at payload[offset:]."""
    if payload[offset : offset + 1] != b"L":
        return payload
    (v,) = struct.unpack("!I", payload[offset + 1 : offset + 5])
    return payload[: offset + 1] + struct.pack("!I", v & ~PA_PROTOCOL_SHM_FLAGS) + payload[offset + 5 :]


def pa_record_source(payload):
    """The source name a CREATE_RECORD_STREAM names ('' for the default or by
    index), from its tagstruct: sample spec, channel map, source index, name."""
    try:
        i = 10
        if payload[i : i + 1] != b"a":  # sample spec: format, channels, rate
            return ""
        i += 1 + 1 + 1 + 4
        if payload[i : i + 1] != b"m":  # channel map: count, positions
            return ""
        i += 2 + payload[i + 1]
        if payload[i : i + 1] != b"L":  # source index
            return ""
        i += 5
        if payload[i : i + 1] == b"t":
            end = payload.index(b"\0", i + 1)
            return payload[i + 1 : end].decode("utf-8", "replace")
    except (IndexError, ValueError):
        pass
    return ""


class PulseFilter:
    """One sandbox client's connection to the user's PulseAudio server."""

    def __init__(self, broker, sandbox, client, upstream_path):
        self.broker = broker
        self.sandbox = sandbox
        self.client = client
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
        self.server.connect(upstream_path)
        self.to_client = threading.Lock()
        self.to_server = threading.Lock()
        self.auth_tag = None
        self.mic = broker.sandboxes[sandbox].get("audio") == "microphone"

    def send_client(self, data):
        with self.to_client:
            self.client.sendall(data)

    def send_server(self, data):
        with self.to_server:
            self.server.sendall(data)

    def run(self):
        t = threading.Thread(target=self.from_server, daemon=True)
        t.start()
        try:
            self.from_client()
        finally:
            for s in (self.client, self.server):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            t.join(2)
            self.client.close()
            self.server.close()

    def from_server(self):
        try:
            while True:
                pkt = pa_read_packet(self.server)
                if pkt is None:
                    break
                desc, payload = pkt
                if desc[1] == PA_CONTROL:
                    cmd = pa_command(payload)
                    if cmd and cmd[0] == PA_REPLY and cmd[1] == self.auth_tag:
                        payload = pa_clear_shm(payload, 10)
                self.send_client(PA_DESC.pack(len(payload), *desc[1:]) + payload)
        except (OSError, ValueError):
            pass
        finally:
            try:
                self.client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def from_client(self):
        try:
            while True:
                pkt = pa_read_packet(self.client)
                if pkt is None:
                    break
                desc, payload = pkt
                if desc[1] != PA_CONTROL:
                    if desc[4] & 0xFF000000:  # shm-referenced audio: never negotiated
                        break
                    self.send_server(PA_DESC.pack(*desc) + payload)
                    continue
                cmd = pa_command(payload)
                if cmd is None:
                    break
                command, tag = cmd
                if command == PA_AUTH:
                    self.auth_tag = tag
                    payload = pa_clear_shm(payload, 10)
                elif command in PA_REFUSED:
                    log(f"{self.sandbox}: audio: refused {PA_REFUSED[command]}")
                    self.send_client(pa_error(tag))
                    continue
                elif command == PA_CREATE_RECORD_STREAM:
                    # Decided off this thread, so the prompt doesn't stall the
                    # connection's playback meanwhile.
                    threading.Thread(target=self.record, args=(tag, payload), daemon=True).start()
                    continue
                self.send_server(pa_packet(payload))
        except (OSError, ValueError):
            pass

    def record(self, tag, payload):
        source = pa_record_source(payload)
        try:
            if not self.mic:
                ok, why = False, "this sandbox has no microphone access"
            else:
                what = (
                    f"record the sound other apps play ({source})"
                    if source.endswith(".monitor")
                    else "use your microphone"
                )
                ok, why = self.broker.decide(
                    self.sandbox, "microphone", ("microphone", source.endswith(".monitor")), what,
                    "until you close the app or the answer's session expires",
                )
            log(f"{self.sandbox}: audio: record {source or '(default source)'}: {why}")
            if ok:
                self.send_server(pa_packet(payload))
            else:
                self.send_client(pa_error(tag))
        except OSError:
            pass


def peer_gone(conn):
    """Whether the other end of `conn` has closed (without consuming data)."""
    try:
        r, _, _ = select.select([conn], [], [], 0)
        if not r:
            return False
        return conn.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT) == b""
    except BlockingIOError:
        return False
    except OSError:
        return True


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
    pulse = {
        name: broker.bind(os.path.join(rundir, f"{name}.pulse"), sb.get("uid"))
        for name, sb in config["sandboxes"].items()
        if sb.get("audio")
    }
    threads = []
    for name, s in sockets.items():
        t = threading.Thread(target=broker.serve, args=(name, s), daemon=True)
        t.start()
        threads.append(t)
    for name, s in pulse.items():
        t = threading.Thread(target=broker.serve_pulse, args=(name, s), daemon=True)
        t.start()
        threads.append(t)
    log(f"serving {len(threads)} sandboxes")
    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
