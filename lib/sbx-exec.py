"""Run commands inside an already-running container sandbox (persistent groups).

  sbx-exec agent --listen SOCK [--idle-exit SECONDS]
      Inside the sandbox (its entry point): accept requests on SOCK and run each
      command as a child, its stdin/stdout/stderr relayed to the caller's.
  sbx-exec run --socket SOCK [--cwd DIR | --home] -- CMD ARGS...
      Outside, from a launcher: run CMD in the sandbox; exit with its status.
      It runs in DIR (default: the caller's directory), which has to be the
      same folder inside the sandbox (or it fails: never somewhere else), or
      with --home in the sandbox's home.
  sbx-exec probe --socket SOCK [--wait SECONDS] [--dir DIR [--grant PROG]]
      Outside, from a launcher, before `run`: wait up to SECONDS for the
      sandbox to answer (exit 3 if it doesn't), and check that it has DIR, the
      same folder at the same path. If it hasn't, `PROG DIR rw` (the root
      attach helper's client) can mount it in, where that hides nothing of the
      sandbox's own; exit 4 if DIR isn't there in the end.

None of the caller's fds enter the sandbox: the sandbox outlives the command,
and a process the command leaves behind would keep them (the caller's terminal
above all, which its shell reads the user's typing from next). The client
relays bytes instead, over the connection, the way ssh does:
  - stdin and stdout both terminals: the agent opens a pty in the sandbox, the
    command's controlling terminal (its own session), set up with the caller's
    terminal settings and size; the client puts its terminal in raw mode and
    relays (Ctrl-C and the like go through as bytes; the pty's line
    discipline turns them into signals). Its stderr is the pty too, unless the
    caller's isn't a terminal (then a pipe, relayed separately).
  - otherwise (a pipe or a file on either end): pipes for all three, relayed
    with stdin's end of file passed on. (So the command doesn't see a terminal
    even on the end that is one.)
When the command exits (or the client goes), the agent closes its end of the
pty or pipes: anything still holding the other end gets EIO or end of file,
not the caller's terminal. The client forwards TERM and HUP (and INT and QUIT
when they reach it rather than the pty) and window size changes.
The caller's environment is overlaid on the sandbox's, except the variables
that locate the sandbox's own services (display, bus, runtime dir), which stay
the sandbox's.

`run`'s wire protocol: the request as a JSON line; the agent's JSON line back
({"ok": true} once the command runs, or {"error": ...}); then frames both ways,
a type byte and a big-endian u32 length before the payload. From the client:
"d" stdin bytes (empty: end of file), "w" a struct winsize, "s" a signal
number byte. From the agent: "o" stdout, "e" stderr, "x" {"exit": code} (JSON,
last).
"""

import argparse
import fcntl
import json
import os
import re
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import termios
import threading
import time
import tty

MAX_REQUEST = 1 << 20
# probe's exit statuses (the launcher falls back on them).
NO_SANDBOX = 3
NO_DIR = 4
# The relay: the request's version (a launcher from before it passed its fds),
# frame header, the largest frame accepted, and how much either side buffers
# for a slow reader before it stops reading what feeds that buffer.
RELAY = 1
HEADER = struct.Struct(">cI")
MAX_FRAME = 1 << 20
CHUNK = 1 << 16
HIGH_WATER = 1 << 20
FORWARDED = [signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP]
# The command's own session and controlling terminal (the pty on its stdin),
# then the command. The agent is threaded, so this isn't a preexec_fn.
CTTY = """\
import fcntl, os, sys, termios
fcntl.ioctl(0, termios.TIOCSCTTY, 0)
try:
    os.execvp(sys.argv[1], sys.argv[1:])
except OSError as e:
    print(f"sbx-exec: {sys.argv[1]}: {e.strerror}", file=sys.stderr)
    sys.exit(127)
"""
# Kept from the sandbox, never taken from the caller.
SANDBOX_ENV = {
    "DBUS_SESSION_BUS_ADDRESS",
    "DBUS_SYSTEM_BUS_ADDRESS",
    "WAYLAND_DISPLAY",
    "DISPLAY",
    "XAUTHORITY",
    "XDG_RUNTIME_DIR",
    "PULSE_SERVER",
    "PIPEWIRE_REMOTE",
    "SSH_AUTH_SOCK",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "PATH",
    "SBX_BROKER",
    "LD_PRELOAD",
    "LD_LIBRARY_PATH",
}


def log(msg):
    print(f"sbx-exec: {msg}", file=sys.stderr, flush=True)


# ── Agent (inside the sandbox) ───────────────────────────────────────────────
def mounts():
    """(mount point, fs type) of every mount in this namespace, in mount order."""
    out = []
    with open("/proc/self/mountinfo") as f:
        for line in f:
            pre, _, post = line.partition(" - ")
            fields = pre.split()
            if len(fields) < 5 or not post:
                continue
            mp = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), fields[4])
            out.append((mp, post.split()[0]))
    return out


def under(path, top):
    return path == top or path.startswith(top.rstrip("/") + "/")


def dir_state(path, ident):
    """What the sandbox has at `path`, compared with the caller's folder there
    (`ident`: its [st_dev, st_ino]; bind mounts keep both):
      {"cwd": "same"}: that folder.
      {"cwd": "missing"}: nothing (a mount can be made there).
      {"cwd": "placeholder", "beneath": [[mount point, dev, ino], ...]}: an
        empty folder on a tmpfs, there only to hold binds below it, which the
        caller checks are its own folders too before covering them.
      {"cwd": "other"}: something of the sandbox's own (its storage, say)."""
    if not isinstance(path, str) or not path.startswith("/"):
        return {"cwd": "other"}
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return {"cwd": "missing"}
    except OSError:
        return {"cwd": "other"}
    if not stat.S_ISDIR(st.st_mode):
        return {"cwd": "other"}
    if ident is None or [st.st_dev, st.st_ino] == list(ident):
        return {"cwd": "same"}
    ms = mounts()
    # The mount the folder is on (the topmost of those stacked at one point).
    holder = max((m for m in reversed(ms) if under(path, m[0])), key=lambda m: len(m[0]), default=None)
    if holder is None or holder[1] != "tmpfs" or holder[0] == path:
        return {"cwd": "other"}
    beneath = sorted({mp for mp, _ in ms if under(mp, path) and mp != path})
    needed = {mp[len(path.rstrip("/")) + 1 :].split("/")[0] for mp in beneath}
    try:
        if set(os.listdir(path)) - needed:
            return {"cwd": "other"}
        out = []
        for mp in beneath:
            m = os.stat(mp)
            out.append([mp, m.st_dev, m.st_ino])
    except OSError:
        return {"cwd": "other"}
    return {"cwd": "placeholder", "beneath": out}


class Agent:
    def __init__(self, idle_exit):
        self.idle_exit = idle_exit
        self.active = 0
        self.last = time.monotonic()
        self.lock = threading.Lock()

    def serve(self, path):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
        s.bind(path)
        os.chmod(path, 0o600)
        s.listen(16)
        if self.idle_exit:
            threading.Thread(target=self.reaper, daemon=True).start()
        log(f"ready on {path}")
        while True:
            conn, _ = s.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def reaper(self):
        while True:
            time.sleep(5)
            with self.lock:
                if self.active == 0 and time.monotonic() - self.last > self.idle_exit:
                    log("idle, exiting")
                    os._exit(0)

    def handle(self, conn):
        with self.lock:
            self.active += 1
        try:
            self.serve_one(conn)
        except Exception as e:
            log(f"request failed: {e}")
        finally:
            conn.close()
            with self.lock:
                self.active -= 1
                self.last = time.monotonic()

    def serve_one(self, conn):
        try:
            req, rest = read_request(conn)
            if req.get("op") == "probe":
                reply = {"ok": True}
                if "cwd" in req:
                    reply.update(dir_state(req["cwd"], req.get("id")))
                send_line(conn, reply)
                return
            session = Session(req)
        except Exception as e:
            try:
                send_line(conn, {"error": str(e)})
            except OSError:
                pass
            return
        try:
            send_line(conn, {"ok": True})
        except OSError:
            session.hang_up()
            return
        session.relay(conn, rest)


def read_request(conn):
    """The request's JSON line, and whatever came after it (the first frames)."""
    buf = bytearray()
    while b"\n" not in buf:
        if len(buf) > MAX_REQUEST:
            raise ValueError("request too large")
        chunk = conn.recv(CHUNK)
        if not chunk:
            raise ValueError("no request")
        buf += chunk
    line, _, rest = bytes(buf).partition(b"\n")
    req = json.loads(line)
    if not isinstance(req, dict):
        raise ValueError("bad request")
    return req, rest


def send_line(conn, obj):
    conn.sendall((json.dumps(obj) + "\n").encode())


def frame(kind, payload=b""):
    return HEADER.pack(kind, len(payload)) + payload


def frames(buf):
    """Complete (type, payload) frames off the front of `buf` (a bytearray)."""
    while len(buf) >= HEADER.size:
        kind, n = HEADER.unpack_from(buf)
        if n > MAX_FRAME:
            raise ValueError("frame too large")
        if len(buf) < HEADER.size + n:
            return
        payload = bytes(buf[HEADER.size : HEADER.size + n])
        del buf[: HEADER.size + n]
        yield kind, payload


def nonblocking(fd):
    fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)


def termios_attrs(attrs, nccs):
    """The caller's terminal settings (tcgetattr's list, control characters as
    ints) checked for shape, for tcsetattr."""
    if (
        not isinstance(attrs, list)
        or len(attrs) != 7
        or not all(isinstance(a, int) and a >= 0 for a in attrs[:6])
        or not isinstance(attrs[6], list)
        or len(attrs[6]) != nccs
        or not all(isinstance(c, int) and 0 <= c < 256 for c in attrs[6])
    ):
        raise ValueError("bad terminal settings")
    return attrs


class Session:
    """One `run`: the command, on a pty or pipes the agent holds, and the relay
    between those and the client's connection."""

    def __init__(self, req):
        if req.get("relay") != RELAY:
            raise ValueError("this launcher's sbx-exec is older than the sandbox's; update it")
        argv = req.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
            raise ValueError("bad argv")
        env = dict(os.environ)
        for k, v in (req.get("env") or {}).items():
            if isinstance(k, str) and isinstance(v, str) and k not in SANDBOX_ENV:
                env[k] = v
        # No cwd: the sandbox's home. Otherwise exactly the caller's folder,
        # never a stand-in (a command started elsewhere than asked works on
        # the wrong files).
        cwd = req.get("cwd")
        if cwd is None:
            cwd = env.get("HOME", "/")
        elif dir_state(cwd, req.get("id"))["cwd"] != "same":
            raise ValueError(f"{cwd} isn't shared with this sandbox")
        if "/" not in argv[0] and shutil.which(argv[0], path=env.get("PATH", os.defpath)) is None:
            raise ValueError(f"{argv[0]}: command not found")
        term = req.get("tty")
        self.master = None
        slave = None
        try:
            if term is not None:
                if not isinstance(term, dict):
                    raise ValueError("bad tty")
                self.master, slave = os.openpty()
                termios.tcsetattr(
                    slave, termios.TCSANOW, termios_attrs(term.get("attrs"), len(termios.tcgetattr(slave)[6]))
                )
                size = term.get("size")
                if isinstance(size, list) and len(size) == 4 and all(isinstance(x, int) and 0 <= x < 65536 for x in size):
                    fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("4H", *size))
                err = slave if term.get("stderr") else subprocess.PIPE
                self.p = subprocess.Popen(
                    [sys.executable, "-IS", "-c", CTTY, *argv],
                    stdin=slave,
                    stdout=slave,
                    stderr=err,
                    cwd=cwd,
                    env=env,
                    start_new_session=True,
                )
            else:
                self.p = subprocess.Popen(
                    argv,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    cwd=cwd,
                    env=env,
                    start_new_session=True,
                )
        except BaseException:
            if self.master is not None:
                os.close(self.master)
            raise
        finally:
            if slave is not None:
                os.close(slave)
        # What the agent reads (fd → frame type) and the command's stdin.
        self.sources = {}
        if self.master is not None:
            self.sources[self.master] = b"o"
            self.stdin = self.master
        else:
            self.sources[self.p.stdout.fileno()] = b"o"
            self.stdin = self.p.stdin.fileno()
        if self.p.stderr is not None:
            self.sources[self.p.stderr.fileno()] = b"e"
        for fd in {*self.sources, self.stdin}:
            nonblocking(fd)

    def close(self, fd):
        """Stop reading or writing `fd` and close it (the pipes are the Popen's
        file objects; the pty master is ours)."""
        self.sources.pop(fd, None)
        if fd == self.stdin:
            self.stdin = None
        if fd in self.sources or fd == self.stdin:
            return
        for f in (self.p.stdin, self.p.stdout, self.p.stderr):
            if f is not None and not f.closed and f.fileno() == fd:
                f.close()
                return
        if fd == self.master:
            self.master = None
        os.close(fd)

    def close_all(self):
        for fd in {*self.sources, *([self.stdin] if self.stdin is not None else [])}:
            self.close(fd)
        if self.master is not None:
            os.close(self.master)
            self.master = None

    def hang_up(self):
        """The client is gone: close our ends (whatever holds the others gets EIO
        or end of file), hang up the command and wait for it."""
        self.close_all()
        try:
            os.killpg(self.p.pid, signal.SIGHUP)
        except (ProcessLookupError, PermissionError):
            pass
        self.p.wait()

    def signal(self, sig):
        if sig not in FORWARDED:
            return
        # INT and QUIT go where the terminal would send them: the pty's
        # foreground process group. TERM and HUP to the command's.
        pgrp = self.p.pid
        if self.master is not None and sig in (signal.SIGINT, signal.SIGQUIT):
            try:
                pgrp = os.tcgetpgrp(self.master)
            except OSError:
                pass
        try:
            os.killpg(pgrp, sig)
        except (ProcessLookupError, PermissionError):
            pass

    def drain(self, out):
        """After the command exits: what it wrote and the agent hasn't read yet.
        A pty's output can lag the writer's exit a little, so it waits briefly
        for more; not for long (and not for much), as whatever the command
        left behind may still be writing."""
        deadline = time.monotonic() + 1.0
        for fd, kind in list(self.sources.items()):
            total = 0
            while total < 4 * HIGH_WATER and time.monotonic() < deadline:
                if fd == self.master:
                    r, _, _ = select.select([fd], [], [], 0.05)
                    if not r:
                        break
                try:
                    data = os.read(fd, CHUNK)
                except BlockingIOError:
                    break
                except OSError:
                    data = b""
                if not data:
                    break
                total += len(data)
                out += frame(kind, data)

    def relay(self, conn, rest):
        conn.setblocking(False)
        cfd = conn.fileno()
        pidfd = os.pidfd_open(self.p.pid)
        inbuf = bytearray(rest)
        out = bytearray()  # to the client
        tocmd = bytearray()  # to the command's stdin
        stdin_eof = False
        try:
            while True:
                for kind, payload in frames(inbuf):
                    if kind == b"d":
                        if payload:
                            if self.stdin is not None:
                                tocmd += payload
                        elif self.master is None:
                            # A pty's end of file is the terminal's (^D, in
                            # raw mode a byte); a pipe's is the caller's.
                            stdin_eof = True
                    elif kind == b"w" and self.master is not None and len(payload) == 8:
                        fcntl.ioctl(self.master, termios.TIOCSWINSZ, payload)
                    elif kind == b"s" and len(payload) == 1:
                        self.signal(payload[0])
                if stdin_eof and not tocmd and self.stdin is not None:
                    self.close(self.stdin)
                want = {pidfd: select.POLLIN}
                if len(out) < HIGH_WATER:
                    for fd in self.sources:
                        want[fd] = want.get(fd, 0) | select.POLLIN
                if out:
                    want[cfd] = select.POLLOUT
                if len(tocmd) < HIGH_WATER:
                    want[cfd] = want.get(cfd, 0) | select.POLLIN
                if tocmd and self.stdin is not None:
                    want[self.stdin] = want.get(self.stdin, 0) | select.POLLOUT
                poll = select.poll()
                for fd, ev in want.items():
                    poll.register(fd, ev)
                for fd, ev in poll.poll():
                    if fd == pidfd:
                        code = self.p.wait()
                        self.drain(out)
                        self.close_all()
                        try:
                            os.killpg(self.p.pid, signal.SIGHUP)
                        except (ProcessLookupError, PermissionError):
                            pass
                        out += frame(b"x", json.dumps({"exit": code}).encode())
                        conn.setblocking(True)
                        conn.settimeout(30)
                        try:
                            conn.sendall(out)
                        except OSError:
                            pass
                        return
                    if fd == cfd:
                        if ev & select.POLLOUT and out:
                            try:
                                del out[: conn.send(out)]
                            except BlockingIOError:
                                pass
                            except OSError:
                                return self.hang_up()
                        if ev & (select.POLLIN | select.POLLHUP | select.POLLERR):
                            try:
                                data = conn.recv(CHUNK)
                            except BlockingIOError:
                                continue
                            except OSError:
                                data = b""
                            if not data:
                                return self.hang_up()
                            inbuf += data
                        continue
                    if fd == self.stdin and ev & (select.POLLOUT | select.POLLERR) and tocmd:
                        try:
                            del tocmd[: os.write(fd, tocmd)]
                        except BlockingIOError:
                            pass
                        except OSError:
                            # The command closed its stdin (or the pty is gone).
                            tocmd.clear()
                            if fd != self.master:
                                self.close(fd)
                    if fd in self.sources and ev & (select.POLLIN | select.POLLHUP | select.POLLERR):
                        try:
                            data = os.read(fd, CHUNK)
                        except BlockingIOError:
                            continue
                        except OSError:
                            data = b""  # EIO: a pty with no slave left
                        if data:
                            out += frame(self.sources[fd], data)
                        else:
                            self.sources.pop(fd)
                            if fd != self.master:
                                self.close(fd)
                    elif fd == self.stdin and fd != self.master and ev & (select.POLLHUP | select.POLLERR):
                        self.close(fd)
        finally:
            os.close(pidfd)
            if self.p.returncode is None:
                self.hang_up()
            else:
                self.close_all()


# ── Client (the launcher, outside) ───────────────────────────────────────────
def ident(path):
    st = os.stat(path)
    return [st.st_dev, st.st_ino]


def connect(path, wait=0.0):
    """Connected to the agent, retrying for up to `wait` seconds (a starting
    sandbox: its socket isn't there yet, or is a stale one it replaces)."""
    deadline = time.monotonic() + wait
    while True:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
        try:
            s.connect(path)
            return s
        except OSError:
            s.close()
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)


def ask(path, req, wait=0.0):
    with connect(path, wait) as s:
        s.sendall((json.dumps(req) + "\n").encode())
        line = s.makefile("rb").readline()
    if not line:
        raise ConnectionError("no reply")
    return json.loads(line)


def probe(args):
    req = {"op": "probe"}
    if args.dir:
        req.update(cwd=args.dir, id=ident(args.dir))
    try:
        r = ask(args.socket, req, args.wait)
    except (OSError, ValueError) as e:
        log(f"{args.socket}: nothing answers ({getattr(e, 'strerror', None) or e})")
        return NO_SANDBOX
    if not args.dir:
        return 0
    if "error" in r:
        # An agent from before probes (the sandbox predates this launcher).
        log(f"the sandbox can't check folders ({r['error']}); restart it to update it")
        return NO_DIR
    state = r.get("cwd")
    if state == "same":
        return 0
    if state == "placeholder":
        for mp, dev, ino in r.get("beneath", []):
            try:
                same = ident(mp) == [dev, ino]
            except OSError:
                same = False
            if not same:
                log(f"{args.dir} would cover the sandbox's own {mp}; not mounting it")
                return NO_DIR
    elif state != "missing":
        log(f"{args.dir} is the sandbox's own folder there, not yours; not mounting over it")
        return NO_DIR
    if not args.grant:
        return NO_DIR
    p = subprocess.run([args.grant, args.dir, "rw"], stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if p.returncode != 0:
        why = (p.stderr.strip().splitlines() or [f"exit {p.returncode}"])[-1]
        log(f"couldn't give the sandbox {args.dir}: {why}")
        return NO_DIR
    try:
        r = ask(args.socket, req)
    except (OSError, ValueError) as e:
        log(f"{args.socket}: {getattr(e, 'strerror', None) or e}")
        return NO_DIR
    if r.get("cwd") != "same":
        log(f"{args.dir} was mounted, but the sandbox doesn't see it there")
        return NO_DIR
    return 0


def winsize(fd):
    return list(struct.unpack("4H", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)))


def write_all(fd, data):
    """All of `data` to the caller's stdout or stderr. They're shared with
    whatever started us, so they're never made non-blocking here (but may be
    already)."""
    view = memoryview(data)
    while view:
        try:
            view = view[os.write(fd, view) :]
        except BlockingIOError:
            select.select([], [fd], [])


def is_open(fd):
    try:
        os.fstat(fd)
        return True
    except OSError:
        return False


def run(args):
    try:
        s = connect(args.socket)
    except OSError as e:
        print(f"sbx-exec: {args.socket}: {e.strerror or e}", file=sys.stderr)
        return 125
    req = {"argv": args.cmd, "env": dict(os.environ), "relay": RELAY}
    if not args.home:
        cwd = args.cwd or os.getcwd()
        req.update(cwd=cwd, id=ident(cwd))
    interactive = os.isatty(0) and os.isatty(1)
    if interactive:
        attrs = termios.tcgetattr(0)
        attrs[6] = [c[0] if isinstance(c, bytes) else c for c in attrs[6]]
        req["tty"] = {"attrs": attrs, "size": winsize(1), "stderr": os.isatty(2)}
    # Signals are queued and the loop woken; the loop forwards them.
    pending = []
    wake_r, wake_w = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
    signal.set_wakeup_fd(wake_w)
    for sig in [*FORWARDED, signal.SIGWINCH]:
        signal.signal(sig, lambda sig, _frame: pending.append(sig))
    s.sendall((json.dumps(req) + "\n").encode())
    buf = bytearray()
    while b"\n" not in buf:
        chunk = s.recv(CHUNK)
        if not chunk:
            print("sbx-exec: the sandbox went away", file=sys.stderr)
            return 125
        buf += chunk
    line, _, rest = bytes(buf).partition(b"\n")
    reply = json.loads(line)
    if "error" in reply:
        why = reply["error"]
        if why == "expected stdin, stdout and stderr":
            why = "the sandbox's sbx-exec is older than this launcher's; restart the sandbox"
        print(f"sbx-exec: {why}", file=sys.stderr)
        return 126
    saved = None
    if interactive:
        saved = termios.tcgetattr(0)
        tty.setraw(0, termios.TCSADRAIN)
    try:
        return pump(s, bytearray(rest), wake_r, pending, interactive)
    finally:
        if saved is not None:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)


def pump(s, inbuf, wake_r, pending, interactive):
    """The client's side of the relay; returns the command's exit status."""
    s.setblocking(False)
    sfd = s.fileno()
    out = bytearray()  # to the agent
    reading = is_open(0)
    if not reading:
        out += frame(b"d")
    while True:
        while pending:
            sig = pending.pop(0)
            if sig == signal.SIGWINCH:
                if interactive:
                    out += frame(b"w", struct.pack("4H", *winsize(1)))
            else:
                out += frame(b"s", bytes([sig]))
        try:
            for kind, payload in frames(inbuf):
                if kind == b"o":
                    write_all(1, payload)
                elif kind == b"e":
                    write_all(2, payload)
                elif kind == b"x":
                    code = json.loads(payload).get("exit", 1)
                    return 128 - code if code < 0 else code
        except BrokenPipeError:
            # Our stdout's reader is gone: as the command would have, die of it.
            return 128 + signal.SIGPIPE
        want = {wake_r: select.POLLIN, sfd: select.POLLIN}
        if out:
            want[sfd] |= select.POLLOUT
        if reading and len(out) < HIGH_WATER:
            want[0] = select.POLLIN
        poll = select.poll()
        for fd, ev in want.items():
            poll.register(fd, ev)
        for fd, ev in poll.poll():
            if fd == wake_r:
                try:
                    while os.read(wake_r, 256):
                        pass
                except BlockingIOError:
                    pass
            elif fd == 0:
                try:
                    data = os.read(0, CHUNK)
                except BlockingIOError:
                    continue
                except OSError:
                    data = b""  # EIO: the terminal hung up
                out += frame(b"d", data)
                if not data:
                    reading = False
            elif fd == sfd:
                if ev & select.POLLOUT and out:
                    try:
                        del out[: s.send(out)]
                    except BlockingIOError:
                        pass
                    except OSError:
                        out.clear()
                if ev & (select.POLLIN | select.POLLHUP | select.POLLERR):
                    try:
                        data = s.recv(CHUNK)
                    except BlockingIOError:
                        continue
                    except OSError:
                        data = b""
                    if not data:
                        print("sbx-exec: the sandbox went away", file=sys.stderr)
                        return 125
                    inbuf += data


def main():
    ap = argparse.ArgumentParser(prog="sbx-exec")
    sub = ap.add_subparsers(dest="mode", required=True)
    a = sub.add_parser("agent")
    a.add_argument("--listen", required=True)
    a.add_argument("--idle-exit", type=int, default=0)
    r = sub.add_parser("run")
    r.add_argument("--socket", required=True)
    where = r.add_mutually_exclusive_group()
    where.add_argument("--cwd")
    where.add_argument("--home", action="store_true")
    r.add_argument("cmd", nargs=argparse.REMAINDER)
    p = sub.add_parser("probe")
    p.add_argument("--socket", required=True)
    p.add_argument("--wait", type=float, default=0.0)
    p.add_argument("--dir")
    p.add_argument("--grant")
    ns = ap.parse_args()
    if ns.mode == "probe":
        sys.exit(probe(ns))
    if ns.mode == "agent":
        # Whatever started the agent may have left these ignored, which its
        # commands would inherit (and then shrug off a forwarded Ctrl-C).
        for sig in (signal.SIGINT, signal.SIGQUIT):
            signal.signal(sig, signal.SIG_DFL)
        Agent(ns.idle_exit).serve(ns.listen)
    else:
        if ns.cmd and ns.cmd[0] == "--":
            ns.cmd = ns.cmd[1:]
        if not ns.cmd:
            ap.error("run: no command")
        sys.exit(run(ns))


if __name__ == "__main__":
    main()
