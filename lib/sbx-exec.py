"""Run commands inside an already-running container sandbox (persistent groups).

  sbx-exec agent --listen SOCK [--idle-exit SECONDS]
      Inside the sandbox (its entry point): accept requests on SOCK and run each
      command as a child, on the caller's own stdin/stdout/stderr.
  sbx-exec run --socket SOCK [--cwd DIR] -- CMD ARGS...
      Outside, from a launcher: run CMD in the sandbox; exit with its status.

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
import signal
import socket
import subprocess
import sys
import threading
import time

MAX_REQUEST = 1 << 20
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
            if len(fds) != 3:
                raise ValueError("expected stdin, stdout and stderr")
            req = json.loads(msg.split(b"\n", 1)[0])
            argv = req["argv"]
            if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
                raise ValueError("bad argv")
            env = dict(os.environ)
            for k, v in (req.get("env") or {}).items():
                if isinstance(k, str) and isinstance(v, str) and k not in SANDBOX_ENV:
                    env[k] = v
            cwd = req.get("cwd")
            if not (isinstance(cwd, str) and os.path.isdir(cwd)):
                cwd = env.get("HOME", "/")
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
def run(args):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    try:
        s.connect(args.socket)
    except OSError as e:
        print(f"sbx-exec: {args.socket}: {e.strerror or e}", file=sys.stderr)
        return 125
    req = {"argv": args.cmd, "cwd": args.cwd or os.getcwd(), "env": dict(os.environ)}
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
    r.add_argument("--cwd")
    r.add_argument("cmd", nargs=argparse.REMAINDER)
    ns = ap.parse_args()
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
