"""sbx-polkit-agent: "system authentication" for an app inside a sandbox VM.

The guest's user has no password and no login session (the app runs over SSH),
so polkit in the guest has nobody to ask: an app that checks a polkit action
with user interaction (1Password's "unlock using system authentication", or its
authorization of a CLI connection) would just be refused. This agent, run as
root in the guest, fills that gap by asking the HOST user instead:

  - It registers as the polkit authentication agent for every process of
    --user whose executable is named --exe (polkit agents can be scoped to one
    unix-process subject; root may register them for any process). One D-Bus
    connection per registration, so polkitd drops exactly that registration
    when it closes. Processes are found by scanning /proc; dead ones are dropped.
  - polkitd calls BeginAuthentication on it for those processes only. For an
    action in --action, it asks the host through the sandbox broker
    ({"op": "authenticate", "action": ...}). With --broker vsock (the VMs) it
    dials the host's vsock relay itself, from a privileged port, rather than
    the guest relay's /run/sbx/broker.sock: that socket and the relay are the
    guest user's, who could otherwise stand in for the host and answer
    "granted". The host
    broker has the user authenticate with THEIR polkit agent (password,
    fingerprint: whatever the host's PAM polkit-1 stack asks) for a host action
    the host config maps this one to, and answers granted/denied.
  - Granted: as root it answers polkitd itself (AuthenticationAgentResponse2)
    with the identity polkit asked for (the guest user), which completes the
    app's authorization. The uid it passes is the user's, not its own: polkitd
    files an agent root registers for a process under that process's user, and
    looks the cookie up there ("No session for cookie" otherwise). Anything else, and every other action: refused.

Trust: the guest's root is inside the VM boundary, like the app; the host
decides, and only for the actions its config maps for this VM.
"""

import argparse
import errno
import fcntl
import json
import os
import queue
import socket
import struct
import sys
import threading
import time

from jeepney import (
    DBusAddress,
    HeaderFields,
    MatchRule,
    MessageType,
    new_error,
    new_method_call,
    new_method_return,
)
from jeepney.io.threading import DBusRouter, open_dbus_connection

AUTHORITY = DBusAddress(
    "/org/freedesktop/PolicyKit1/Authority",
    bus_name="org.freedesktop.PolicyKit1",
    interface="org.freedesktop.PolicyKit1.Authority",
)
AGENT_IFACE = "org.freedesktop.PolicyKit1.AuthenticationAgent"
AGENT_PATH = "/org/otisroot/SandboxPolkitAgent"
ERR_FAILED = "org.freedesktop.PolicyKit1.Error.Failed"
ERR_CANCELLED = "org.freedesktop.PolicyKit1.Error.Cancelled"
MAX_AGENTS = 64
BROKER_TIMEOUT = 330
HOST_CID = 2
IOCTL_VM_SOCKETS_GET_LOCAL_CID = 0x7B9


def log(msg):
    print(f"sbx-polkit-agent: {msg}", file=sys.stderr, flush=True)


# ── Processes ────────────────────────────────────────────────────────────────


def proc_info(pid):
    """(real uid, start time in clock ticks, executable basename) or None."""
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii", errors="replace") as f:
            start = int(f.read().rsplit(")", 1)[1].split()[19])
        uid = None
        with open(f"/proc/{pid}/status", encoding="ascii", errors="replace") as f:
            for line in f:
                if line.startswith("Uid:"):
                    uid = int(line.split()[1])
                    break
        exe = os.path.basename(os.readlink(f"/proc/{pid}/exe"))
    except (OSError, ValueError, IndexError):
        return None
    if uid is None:
        return None
    return uid, start, exe


def scan(uid, names):
    """{(pid, start)} of the matching processes."""
    out = set()
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        info = proc_info(int(d))
        if info and info[0] == uid and info[2] in names:
            out.add((int(d), info[1]))
    return out


# ── Host side ────────────────────────────────────────────────────────────────


def local_cid():
    with open("/dev/vsock", "rb") as f:
        return struct.unpack("I", fcntl.ioctl(f, IOCTL_VM_SOCKETS_GET_LOCAL_CID, b"\0" * 4))[0]


def connect_broker(broker):
    """A connection to the host broker: "vsock" dials the host relay directly
    (port = this VM's CID, as the guest relay does) from a port below 1024,
    which only the guest's root can bind; anything else is a unix socket."""
    if broker != "vsock":
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
        s.settimeout(1.0)
        s.connect(broker)
        return s
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    try:
        for port in range(1023, 511, -1):
            try:
                s.bind((socket.VMADDR_CID_ANY, port))
                break
            except OSError as e:
                if e.errno != errno.EADDRINUSE:
                    raise
        else:
            raise OSError(errno.EADDRINUSE, "no free privileged vsock port")
        s.settimeout(1.0)
        s.connect((HOST_CID, local_cid()))
        s.sendall(b"broker\n")
    except BaseException:
        s.close()
        raise
    return s


def ask_host(broker, action, cancelled):
    """Have the host user authenticate for `action`. True when granted. The
    connection is closed early when polkit cancels (the host broker then
    cancels the user's dialog)."""
    s = None
    try:
        s = connect_broker(broker)
        s.sendall(json.dumps({"op": "authenticate", "action": action}).encode() + b"\n")
        buf = b""
        deadline = time.monotonic() + BROKER_TIMEOUT
        while True:
            if cancelled.is_set() or time.monotonic() > deadline:
                return False, "cancelled"
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                return False, "the host broker closed the connection"
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    msg = json.loads(line)
                except ValueError:
                    return False, "bad reply from the host broker"
                kind = msg.get("type") if isinstance(msg, dict) else None
                if kind == "granted":
                    return True, "granted"
                if kind in ("denied", "error"):
                    return False, str(msg.get("reason") or msg.get("message") or kind)[:200]
            if len(buf) > 65536:
                return False, "reply too long"
    except OSError as e:
        return False, f"host broker unreachable: {e.strerror or e}"
    finally:
        if s is not None:
            s.close()


# ── The agent ────────────────────────────────────────────────────────────────


class Agent:
    """One registration: its own bus connection, scoped to one process."""

    def __init__(self, pid, start, cfg):
        self.pid, self.start, self.cfg = pid, start, cfg
        self.conn = open_dbus_connection(bus="SYSTEM")
        self.router = DBusRouter(self.conn)
        self.cancel = {}  # cookie -> threading.Event
        self.lock = threading.Lock()
        rule = MatchRule(type="method_call", path=AGENT_PATH)
        self.queue = queue.Queue()
        self.filter = self.router.filter(rule, queue=self.queue)
        self.closed = False
        threading.Thread(target=self.serve, daemon=True).start()
        subject = (
            "unix-process",
            {"pid": ("u", pid), "start-time": ("t", start), "uid": ("i", cfg.uid)},
        )
        reply = self.router.send_and_get_reply(
            new_method_call(
                AUTHORITY,
                "RegisterAuthenticationAgent",
                "(sa{sv})ss",
                (subject, os.environ.get("LANG") or "C.UTF-8", AGENT_PATH),
            ),
            timeout=10,
        )
        if reply.header.message_type == MessageType.error:
            self.close()
            raise RuntimeError(f"polkit refused the registration: {reply.body}")

    def close(self):
        if self.closed:
            return
        self.closed = True
        for ev in list(self.cancel.values()):
            ev.set()
        try:
            self.filter.close()
        except KeyError:
            pass
        self.queue.put(None)
        try:
            self.router.close()
        finally:
            self.conn.close()

    def serve(self):
        while True:
            msg = self.queue.get()
            if msg is None:
                return
            member = msg.header.fields.get(HeaderFields.member)
            iface = msg.header.fields.get(HeaderFields.interface, AGENT_IFACE)
            if iface != AGENT_IFACE:
                member = None
            if member == "BeginAuthentication":
                threading.Thread(target=self.begin, args=(msg,), daemon=True).start()
            elif member == "CancelAuthentication":
                cookie = msg.body[0] if msg.body else ""
                with self.lock:
                    ev = self.cancel.get(cookie)
                if ev:
                    ev.set()
                self.reply(new_method_return(msg))
            else:
                self.reply(new_error(msg, "org.freedesktop.DBus.Error.UnknownMethod", "s", ("unknown method",)))

    def reply(self, msg):
        try:
            self.router.send(msg)
        except OSError as e:
            log(f"pid {self.pid}: could not reply: {e}")

    def begin(self, msg):
        try:
            action, _message, _icon, _details, cookie, identities = msg.body
        except ValueError:
            return self.reply(new_error(msg, ERR_FAILED, "s", ("bad arguments",)))
        if action not in self.cfg.actions:
            log(f"pid {self.pid}: {action}: not an action this agent handles; refused")
            return self.reply(new_error(msg, ERR_FAILED, "s", ("not handled",)))
        # The identity polkit will accept: the guest user (auth_self).
        identity = None
        for kind, details in identities:
            uid = details.get("uid")
            if kind == "unix-user" and uid is not None and uid[1] == self.cfg.uid:
                identity = (kind, {"uid": ("u", self.cfg.uid)})
        if identity is None:
            log(f"pid {self.pid}: {action}: polkit didn't offer the user's identity; refused")
            return self.reply(new_error(msg, ERR_FAILED, "s", ("no usable identity",)))
        ev = threading.Event()
        with self.lock:
            self.cancel[cookie] = ev
        try:
            ok, why = ask_host(self.cfg.broker, action, ev)
            log(f"pid {self.pid}: {action}: {why}")
            if not ok:
                err = ERR_CANCELLED if ev.is_set() else ERR_FAILED
                return self.reply(new_error(msg, err, "s", (why,)))
            r = self.router.send_and_get_reply(
                new_method_call(
                    AUTHORITY,
                    "AuthenticationAgentResponse2",
                    "us(sa{sv})",
                    (self.cfg.uid, cookie, identity),
                ),
                timeout=10,
            )
            if r.header.message_type == MessageType.error:
                log(f"pid {self.pid}: {action}: polkit refused the response: {r.body}")
                return self.reply(new_error(msg, ERR_FAILED, "s", ("response refused",)))
            self.reply(new_method_return(msg))
        except Exception as e:  # never leave polkit waiting
            log(f"pid {self.pid}: {action}: {type(e).__name__}: {e}")
            self.reply(new_error(msg, ERR_FAILED, "s", ("internal error",)))
        finally:
            with self.lock:
                self.cancel.pop(cookie, None)


class Config:
    def __init__(self, uid, names, actions, broker):
        self.uid = uid
        self.names = set(names)
        self.actions = set(actions)
        self.broker = broker


class Watcher:
    """Keeps one Agent per live matching process."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.agents = {}  # (pid, start) -> Agent
        self.failed = {}  # (pid, start) -> time of the last failed registration

    def step(self):
        now = time.monotonic()
        live = scan(self.cfg.uid, self.cfg.names)
        for key in list(self.agents):
            if key not in live:
                self.agents.pop(key).close()
        for key in live - set(self.agents):
            if len(self.agents) >= MAX_AGENTS or now - self.failed.get(key, -60) < 5:
                continue
            try:
                self.agents[key] = Agent(key[0], key[1], self.cfg)
                self.failed.pop(key, None)
            except Exception as e:
                self.failed[key] = now
                log(f"pid {key[0]}: could not register: {e}")
        for key in [k for k in self.failed if k not in live]:
            del self.failed[key]

    def run(self, interval, stop=None):
        while stop is None or not stop.is_set():
            self.step()
            time.sleep(interval)
        for a in self.agents.values():
            a.close()


def main(argv=None):
    import pwd

    ap = argparse.ArgumentParser(prog="sbx-polkit-agent")
    ap.add_argument("--user", required=True, help="the guest user whose processes are served")
    ap.add_argument("--exe", action="append", required=True, help="executable basename to serve (repeatable)")
    ap.add_argument("--action", action="append", required=True, help="polkit action to handle (repeatable)")
    ap.add_argument(
        "--broker",
        default="/run/sbx/broker.sock",
        help='the broker\'s unix socket, or "vsock" for the host relay directly (VMs)',
    )
    ap.add_argument("--interval", type=float, default=0.5)
    a = ap.parse_args(argv)
    if os.geteuid() != 0:
        raise SystemExit("sbx-polkit-agent: must run as root (it answers polkit for the user)")
    cfg = Config(pwd.getpwnam(a.user).pw_uid, a.exe, a.action, a.broker)
    log(f"serving {sorted(cfg.actions)} for {a.user}'s {sorted(cfg.names)} processes")
    Watcher(cfg).run(a.interval)


if __name__ == "__main__":
    main()
