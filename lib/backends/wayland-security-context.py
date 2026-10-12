# Create a wp_security_context_v1 Wayland socket for a sandboxed app.
#
# Sandboxes must NOT get the compositor's raw socket: any client on it can bind
# privileged globals (wlr-screencopy / ext-image-copy-capture → silent
# screenshots, e.g. by running the host's allow-listed `grim` from inside the
# sandbox; data-control → clipboard sniffing; virtual keyboard/pointer → input
# injection; foreign-toplevel → window list). With wp_security_context_v1 the
# compositor itself accepts connections on a socket we hand it and tags every
# client from that socket as sandboxed; Hyprland (and wlroots compositors) then
# expose only an allowlist of ordinary globals to those clients. This is the
# same mechanism Flatpak uses. Pure-Python wire protocol, no dependencies.
#
# Usage:
#   run  <socket-path> <app-id> -- <cmd> [args...]
#       Create the socket, run <cmd> (with WAYLAND_DISPLAY pointing at it) as a
#       child, and remove the socket when it exits. Exit status = the child's.
#   hold <socket-path> <app-id>
#       Create the socket and keep it until SIGTERM/SIGINT/SIGHUP.
# The compositor stops listening when this process exits (close_fd hangup).
# Refuses (exit 1) if the compositor lacks wp_security_context_manager_v1 —
# failing closed rather than silently handing out the raw socket. One exception:
# a nested `run` from INSIDE a sandbox (e.g. r2modman launching steam) sees an
# upstream that is already a security-context socket, where the manager global
# is hidden. The child env carries WAYLAND_SECURITY_CONTEXT=<socket we made>; if
# the upstream is exactly that socket, it's passed through unchanged (the nested
# app gets the same restricted view, nothing more).
import array
import ctypes
import os
import signal
import socket
import struct
import subprocess
import sys

PROG = "wayland-security-context"
ENGINE = "nixpak"
MARKER = "WAYLAND_SECURITY_CONTEXT"
PR_SET_PDEATHSIG = 1


class WaylandError(Exception):
    pass


class Conn:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
        self.sock.connect(path)
        self.next_id = 2  # 1 is wl_display
        self.buf = b""

    def new_id(self):
        i = self.next_id
        self.next_id += 1
        return i

    def send(self, obj, opcode, args=b"", fds=()):
        size = 8 + len(args)
        msg = struct.pack("<II", obj, (size << 16) | opcode) + args
        anc = []
        if fds:
            anc = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))]
        self.sock.sendmsg([msg], anc)

    def recv(self):
        while True:
            if len(self.buf) >= 8:
                obj, word = struct.unpack_from("<II", self.buf)
                size, opcode = word >> 16, word & 0xFFFF
                if len(self.buf) >= size:
                    body, self.buf = self.buf[8:size], self.buf[size:]
                    return obj, opcode, body
            data = self.sock.recv(65536)
            if not data:
                raise WaylandError("compositor closed the connection")
            self.buf += data


def u32(v):
    return struct.pack("<I", v)


def wl_string(s):
    b = s.encode() + b"\0"
    return u32(len(b)) + b + b"\0" * (-len(b) % 4)


def read_string(body, off):
    (n,) = struct.unpack_from("<I", body, off)
    s = body[off + 4 : off + 4 + n - 1].decode()
    return s, off + 4 + n + (-n % 4)


def roundtrip(c):
    """wl_display.sync; return once the compositor has processed everything."""
    cb = c.new_id()
    c.send(1, 0, u32(cb))
    while True:
        obj, op, body = c.recv()
        if obj == 1 and op == 0:  # wl_display.error
            (oid, code) = struct.unpack_from("<II", body)
            msg, _ = read_string(body, 8)
            raise WaylandError(f"protocol error on object {oid} (code {code}): {msg}")
        if obj == cb and op == 0:  # wl_callback.done
            return
        yield obj, op, body


def create(sock_path, app_id, instance_id):
    display = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    upstream = display if display.startswith("/") else os.path.join(runtime, display)

    c = Conn(upstream)
    registry = c.new_id()
    c.send(1, 1, u32(registry))  # wl_display.get_registry
    mgr_name = None
    for obj, op, body in roundtrip(c):
        if obj == registry and op == 0:  # wl_registry.global
            (name,) = struct.unpack_from("<I", body)
            iface, _ = read_string(body, 4)
            if iface == "wp_security_context_manager_v1":
                mgr_name = name
    if mgr_name is None:
        raise WaylandError("compositor does not support wp_security_context_manager_v1")

    mgr = c.new_id()
    c.send(registry, 0, u32(mgr_name) + wl_string("wp_security_context_manager_v1") + u32(1) + u32(mgr))

    # The listening socket the compositor will accept() on, and a pipe whose
    # write end we keep: the compositor drops the context when it hangs up. The
    # socket is bound under a temporary name and only renamed to <sock_path>
    # once the compositor has acknowledged the committed context, so anything
    # waiting for <sock_path> never sees a half-set-up (or stale) socket.
    tmp_path = f"{sock_path}.tmp-{os.getpid()}"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    old = os.umask(0o077)
    try:
        listener.bind(tmp_path)
    finally:
        os.umask(old)
    close_r, close_w = os.pipe2(os.O_CLOEXEC)
    try:
        listener.listen(16)
        ctx = c.new_id()
        c.send(mgr, 1, u32(ctx), fds=(listener.fileno(), close_r))  # create_listener
        c.send(ctx, 1, wl_string(ENGINE))  # set_sandbox_engine
        c.send(ctx, 2, wl_string(app_id))  # set_app_id
        c.send(ctx, 3, wl_string(instance_id))  # set_instance_id
        c.send(ctx, 4)  # commit
        c.send(ctx, 0)  # destroy (the context lives on until close_fd hangs up)
        for _ in roundtrip(c):
            pass
        ino = os.stat(tmp_path).st_ino
        os.rename(tmp_path, sock_path)
    except BaseException:
        os.close(close_w)
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
        raise
    finally:
        # The compositor holds its own copies of the listen fd and close_r.
        listener.close()
        os.close(close_r)
        c.sock.close()
    return close_w, ino


def main(argv):
    if len(argv) == 3 and argv[0] == "hold":
        mode, sock_path, app_id, cmd = "hold", argv[1], argv[2], None
    elif len(argv) >= 5 and argv[0] == "run" and argv[3] == "--":
        mode, sock_path, app_id, cmd = "run", argv[1], argv[2], argv[4:]
    else:
        print(f"{PROG}: usage: run <socket> <app-id> -- <cmd...> | hold <socket> <app-id>", file=sys.stderr)
        return 2
    wd = os.environ.get("WAYLAND_DISPLAY")
    if mode == "run" and wd and wd == os.environ.get(MARKER):
        os.execvp(cmd[0], cmd)  # already inside a security context: pass through
    stop_signals = {signal.SIGTERM, signal.SIGINT, signal.SIGHUP}
    if mode == "hold":
        # Blocked from the start and collected with sigwait(): no window where a
        # stop signal is lost (pause() after a flag check can sleep forever).
        signal.pthread_sigmask(signal.SIG_BLOCK, stop_signals)
        # Die with the launcher: if it is SIGKILLed (its trap never runs), don't
        # linger holding the socket + compositor context forever.
        parent = os.getppid()
        libc = ctypes.CDLL(None, use_errno=True)
        libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0)
        if os.getppid() != parent:  # parent already gone before prctl took effect
            return 1
    try:
        close_w, ino = create(sock_path, app_id, f"{app_id}-{os.getpid()}")
    except (OSError, WaylandError) as e:
        print(f"{PROG}: refusing to start {app_id}: {e}", file=sys.stderr)
        return 1

    def cleanup():
        # Only remove the socket if it is still OURS: a later launch may have
        # replaced <sock_path> with its own.
        try:
            if os.stat(sock_path).st_ino == ino:
                os.unlink(sock_path)
        except FileNotFoundError:
            pass
        os.close(close_w)

    if mode == "hold":
        signal.sigwait(stop_signals)
        cleanup()
        return 0

    # A bare name when the socket sits in XDG_RUNTIME_DIR: nixpak binds
    # "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" into the sandbox.
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    display = sock_path
    if runtime and os.path.dirname(sock_path) == runtime.rstrip("/"):
        display = os.path.basename(sock_path)
    env = dict(os.environ, WAYLAND_DISPLAY=display, **{MARKER: display})
    child = subprocess.Popen(cmd, env=env)
    # Terminal signals reach the whole foreground process group already; forward
    # the ones sent to us alone (e.g. a `kill` of the wrapper) to the child.
    for s in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, lambda sig, _f: child.send_signal(sig))
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    rc = child.wait()
    cleanup()
    return rc if rc >= 0 else 128 - rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
