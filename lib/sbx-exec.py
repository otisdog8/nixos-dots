"""Run commands inside an already-running container sandbox (persistent groups).

  sbx-exec agent --listen SOCK [--idle-exit SECONDS]
      Inside the sandbox (its entry point): accept requests on SOCK and run each
      command as a child, on the caller's own stdin/stdout/stderr.
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

Each request passes the caller's fds 0-2 (SCM_RIGHTS), so a terminal works as
usual: the command reads and writes the caller's tty directly. It isn't the
command's controlling terminal (that would take stealing it from the caller's
session), so the client forwards what the terminal would have delivered:
INT, QUIT, TERM, HUP and WINCH (window size changes, read back with TIOCGWINSZ
on the fd). The caller's environment is overlaid on the sandbox's, except the
variables that locate the sandbox's own services (display, bus, runtime dir),
which stay the sandbox's.
"""

import argparse
import array
import json
import os
import re
import signal
import socket
import stat
import subprocess
import sys
import threading
import time

MAX_REQUEST = 1 << 20
# probe's exit statuses (the launcher falls back on them).
NO_SANDBOX = 3
NO_DIR = 4
FORWARDED = [signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP, signal.SIGWINCH]
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
        fds = []
        try:
            fds_arr = array.array("i")
            msg, anc, _, _ = conn.recvmsg(MAX_REQUEST, socket.CMSG_SPACE(3 * fds_arr.itemsize))
            for level, kind, data in anc:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    fds_arr.frombytes(data[: len(data) - (len(data) % fds_arr.itemsize)])
            fds = list(fds_arr)
            req = json.loads(msg.split(b"\n", 1)[0])
            if req.get("op") == "probe":
                reply = {"ok": True}
                if "cwd" in req:
                    reply.update(dir_state(req["cwd"], req.get("id")))
                try:
                    conn.sendall((json.dumps(reply) + "\n").encode())
                except OSError:
                    pass
                self.done(conn, fds)
                return
            if len(fds) != 3:
                raise ValueError("expected stdin, stdout and stderr")
            argv = req["argv"]
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
            p = subprocess.Popen(
                argv,
                stdin=fds[0],
                stdout=fds[1],
                stderr=fds[2],
                cwd=cwd,
                env=env,
                start_new_session=True,
            )
        except Exception as e:
            try:
                conn.sendall((json.dumps({"error": str(e)}) + "\n").encode())
            except OSError:
                pass
            self.done(conn, fds)
            return
        for fd in fds:
            os.close(fd)
        fds = []

        def signals():
            f = conn.makefile("rb")
            for line in f:
                try:
                    sig = int(line)
                    if sig in FORWARDED:
                        os.killpg(p.pid, sig)
                except (ValueError, ProcessLookupError, PermissionError):
                    pass
            # The client went away (its terminal closed): hang up the command.
            try:
                os.killpg(p.pid, signal.SIGHUP)
            except (ProcessLookupError, PermissionError):
                pass

        threading.Thread(target=signals, daemon=True).start()
        code = p.wait()
        try:
            conn.sendall((json.dumps({"exit": code}) + "\n").encode())
        except OSError:
            pass
        self.done(conn, fds)

    def done(self, conn, fds):
        for fd in fds:
            try:
                os.close(fd)
            except OSError:
                pass
        conn.close()
        with self.lock:
            self.active -= 1
            self.last = time.monotonic()


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


def run(args):
    try:
        s = connect(args.socket)
    except OSError as e:
        print(f"sbx-exec: {args.socket}: {e.strerror or e}", file=sys.stderr)
        return 125
    req = {"argv": args.cmd, "env": dict(os.environ)}
    if not args.home:
        cwd = args.cwd or os.getcwd()
        req.update(cwd=cwd, id=ident(cwd))
    s.sendmsg(
        [(json.dumps(req) + "\n").encode()],
        [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [0, 1, 2]))],
    )
    lock = threading.Lock()

    def forward(sig, _frame):
        with lock:
            try:
                s.sendall(f"{int(sig)}\n".encode())
            except OSError:
                pass

    for sig in FORWARDED:
        signal.signal(sig, forward)
    f = s.makefile("rb")
    while True:
        try:
            line = f.readline()
            break
        except InterruptedError:
            continue
    if not line:
        print("sbx-exec: the sandbox went away", file=sys.stderr)
        return 125
    reply = json.loads(line)
    if "error" in reply:
        print(f"sbx-exec: {reply['error']}", file=sys.stderr)
        return 126
    code = reply.get("exit", 1)
    return 128 - code if code < 0 else code


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
