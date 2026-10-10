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
  {"op": "clipboard", "data": <base64 text>, "sensitive": bool?}
  {"op": "clipboard", "clear": true}
      → {"type": "granted"} once the text is on the user's clipboard (marked
        as a secret for clipboard managers when `sensitive`), or once it is
        cleared, which happens only while what is on it is still what this
        sandbox put there. For sandboxes with the clipboard grant only
        (a VM's data-control copies, lib/vm/clip-guest.py); never asks, and
        never reads the clipboard.
  any refusal → {"type": "denied", "reason": "..."}; bad input → {"type": "error", ...}

Audio: a sandbox with audio also gets $XDG_RUNTIME_DIR/sbx-broker/<sandbox>.pulse,
a PulseAudio socket in front of the user's own (PulseFilter below): playback
passes, recording (the microphone, or a monitor of what other apps play) needs
the sandbox's microphone capability and the user's approval, volume, mute and
the like pass only for the client's own streams, and whatever reconfigures the
sound server for everyone is refused.

Every request not covered by a rule asks the user with sbx-prompt (a desktop
dialog naming the sandbox, what it wants, and the sandbox's stated reason,
labelled as such), one dialog per sandbox at a time. Rules come from the Nix
config (modules.sandbox.broker).
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
import unicodedata

MAX_REQUEST = 64 * 1024
MAX_ARGS = 256
EXEC_LINES = 8  # dialog lines for a command, which must fit in them
SESSION_TTL = 12 * 3600
# One dialog per sandbox at a time; up to PROMPT_QUEUE more of its requests wait
# their turn (an app asking for the microphone and then the camera), the rest
# are refused, so a sandbox can't bury the desktop in dialogs.
PROMPT_QUEUE = 4
# Connections a sandbox may hold open at once, to the broker and to its audio
# socket (each costs a thread or two here).
MAX_CONNS = 32
MAX_PULSE_CONNS = 32
# authenticate: one at a time per sandbox; after AUTH_FAILS failed or dismissed
# authentications in a row, refuse for AUTH_PAUSE seconds (a compromised
# sandbox can't keep the user's password dialog on screen).
# clipboard: the text a sandbox may put on the clipboard at once.
MAX_CLIPBOARD = 32 * 1024
AUTH_FAILS = 3
AUTH_PAUSE = 300
AUTH_TIMEOUT = 300


def log(msg):
    print(f"sbx-broker: {msg}", file=sys.stderr, flush=True)


# ── Showing what a sandbox sent ──────────────────────────────────────────────
# Dialogs are plain text without wrapping. Whatever the sandbox chose (command,
# folder, reason, device name) goes on lines of its own behind GUTTER, escaped so
# it can't start a new line, reorder or hide text (bidi controls, zero-width and
# other invisible characters), and cut to FIELD_WIDTH characters a line: the
# lines without the gutter (who asks, for what) are always the broker's own.
GUTTER = "┃ "
FIELD_WIDTH = 80
UNTRUSTED_NOTE = (
    f"Lines marked {GUTTER.strip()} were sent by the sandbox and are unverified; control and"
    "\ninvisible characters in them are shown escaped (\\n, \\u202e, …)."
)
# Categories escaped: controls, format (bidi, zero-width), surrogates, private
# use, unassigned, line/paragraph separators, enclosing marks.
_UNSAFE = {"Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp", "Me"}
# Blank or default-ignorable characters outside those categories.
_INVISIBLE = {0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0}
_INVISIBLE_RANGES = ((0x180B, 0x180F), (0xFE00, 0xFE0F), (0xE0100, 0xE01EF))
_NAMED = {"\n": "\\n", "\r": "\\r", "\t": "\\t"}
MAX_MARKS = 3  # combining marks in a row before the rest are escaped (stacked
# marks draw over the lines above and below)


def escape(s, ascii_only=False, backslash=True):
    """`s` with every character that could hide or fake text escaped visibly
    (\\n, \\x1b, \\u202e, …): one line, nothing invisible. `ascii_only` also
    escapes everything outside printable ASCII (look-alike letters). With
    `backslash`, a backslash is shown doubled, so an escape can't be faked."""
    out = []
    marks = 0
    for c in str(s):
        o = ord(c)
        cat = unicodedata.category(c)
        marks = marks + 1 if cat[0] == "M" else 0
        if c == "\\":
            out.append("\\\\" if backslash else c)
        elif c in _NAMED:
            out.append(_NAMED[c])
        elif (
            cat in _UNSAFE
            or (cat == "Zs" and c != " ")
            or o in _INVISIBLE
            or any(lo <= o <= hi for lo, hi in _INVISIBLE_RANGES)
            or marks > MAX_MARKS
            or (ascii_only and not 0x20 <= o < 0x7F)
        ):
            out.append(f"\\x{o:02x}" if o < 0x100 else f"\\u{o:04x}" if o < 0x10000 else f"\\U{o:08x}")
        else:
            out.append(c)
    return "".join(out)


def block(text, max_lines=4, width=FIELD_WIDTH):
    """Already escaped sandbox text as dialog lines behind the gutter, `width`
    characters each, at most `max_lines` of them, then (the broker's own line)
    how much was left out."""
    lines = [text[i : i + width] for i in range(0, len(text), width)] or [""]
    out = "\n".join(GUTTER + line for line in lines[:max_lines])
    rest = len(text) - width * max_lines
    if rest > 0:
        out += f"\n… ({rest} more characters not shown)"
    return out


def untrusted(s, max_lines=4):
    return block(escape(s), max_lines)


def show_argv(argv):
    """A command as shell words, each escaped first (the program also to
    ASCII, so a look-alike can't pass for a familiar one)."""
    return " ".join(shlex.quote(escape(a, ascii_only=(i == 0))) for i, a in enumerate(argv))


def scrub(text, width=2 * FIELD_WIDTH):
    """The last pass over a whole dialog text: the broker's own lines are kept
    (and anything unsafe on them escaped, backslashes as they are), and each is
    cut to `width`."""
    out = []
    for line in str(text).split("\n"):
        line = escape(line, backslash=False)
        if len(line) > width:
            line = line[:width] + f" … ({len(line) - width} more characters not shown)"
        out.append(line)
    return "\n".join(out)


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
        self.turns = {}  # sandbox -> lock held while its dialog is on screen
        self.waiting = {}  # sandbox -> requests on screen or waiting their turn
        self.conns = {}  # (sandbox, kind) -> connections open
        self.clips = {}  # sandbox -> the wl-copy holding what it copied

    def take_slot(self, sandbox, kind, limit):
        """Count one more open connection of `kind` for `sandbox`, unless it
        already has `limit` of them."""
        with self.lock:
            n = self.conns.get((sandbox, kind), 0)
            if n >= limit:
                return False
            self.conns[(sandbox, kind)] = n + 1
            return True

    def free_slot(self, sandbox, kind):
        with self.lock:
            self.conns[(sandbox, kind)] -= 1

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

    def approved_before(self, sandbox, key):
        with self.lock:
            exp = self.approved.get((sandbox, key))
            return bool(exp and exp > time.time())

    def decide(self, sandbox, op, key, summary, detail, as_="user", argv=None, allow_session=True, conn=None):
        """Whether to grant a request: by rule, by an earlier answer for the
        session, or by asking the user. `summary` and `detail` are the dialog's
        text: anything the sandbox sent in them must already be shown through
        untrusted()/block() (scrub() here only escapes what slipped through).
        With `conn`, a request whose sandbox hung up while it waited for its
        turn is dropped instead of asked."""
        action = self.rule_for(sandbox, op, as_, argv or [])
        if action == "deny":
            return False, "denied by rule"
        if action == "allow":
            return True, "allowed by rule"
        if self.approved_before(sandbox, key):
            return True, "allowed earlier this session"
        with self.lock:
            n = self.waiting.get(sandbox, 0)
            if n > PROMPT_QUEUE:
                return False, "too many requests from this sandbox are waiting for an answer"
            self.waiting[sandbox] = n + 1
            turn = self.turns.setdefault(sandbox, threading.Lock())
        try:
            with turn:
                # The answer to a request ahead in line may cover this one.
                if self.approved_before(sandbox, key):
                    return True, "allowed earlier this session"
                if conn is not None and peer_gone(conn):
                    return False, "the sandbox withdrew the request"
                return self.ask(sandbox, key, summary, detail, allow_session)
        finally:
            with self.lock:
                self.waiting[sandbox] -= 1

    def ask(self, sandbox, key, summary, detail, allow_session):
        args = [self.prompt, "--timeout", "90"]
        if not allow_session:
            args.append("--no-session")
        args += ["--", self.sandboxes[sandbox]["label"], scrub(summary), scrub(detail)]
        try:
            r = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
            answer = r.stdout.strip()
        except (OSError, subprocess.TimeoutExpired) as e:
            log(f"prompt failed: {e}")
            return False, "could not ask the user"
        if answer == "session" and allow_session:
            with self.lock:
                self.approved[(sandbox, key)] = time.time() + SESSION_TTL
            return True, "allowed for the session"
        if answer in ("once", "session"):
            return True, "allowed once"
        return False, "denied by the user"

    @staticmethod
    def with_reason(detail, req):
        """`detail`, then the reason the sandbox gave (if any) and the note on
        sandbox-supplied lines. Every op whose dialog shows sandbox text ends
        its detail with this."""
        reason = req.get("reason") or ""
        if reason:
            detail += "\n\nThe reason it gives:\n" + untrusted(reason)
        return detail + "\n\n" + UNTRUSTED_NOTE

    # ── Operations ───────────────────────────────────────────────────────────
    def op_exec(self, sandbox, req, send, conn=None):
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
        # The folder is part of what the user approves, for root as for the
        # user: it's shown, and pinning it wouldn't confine anything (the
        # command itself could be `sh -c 'cd X && ...'`).
        cwd = req.get("cwd") or os.environ.get("HOME", "/")
        if not isinstance(cwd, str) or not os.path.isabs(cwd) or not os.path.isdir(cwd):
            cwd = os.environ.get("HOME", "/")
        # Shown and remembered as what it is, not as a link to it.
        cwd = os.path.realpath(cwd)
        cmd = show_argv(argv)
        # The user approves exactly what they read: never a command (or
        # folder) cut short for the dialog.
        if len(cmd) > EXEC_LINES * FIELD_WIDTH or len(escape(cwd)) > 2 * FIELD_WIDTH:
            return send({"type": "denied", "reason": "the command is too long to show in full in a dialog"})
        who = "ROOT" if as_ == "root" else "your user"
        summary = f"run a command outside its sandbox as {who}"
        detail = self.with_reason(f"The command:\n{block(cmd, EXEC_LINES)}\nIn the folder:\n{untrusted(cwd, 2)}", req)
        ok, why = self.decide(
            sandbox,
            "exec",
            # The folder too: the same command elsewhere may run other code
            # (a Makefile, a .git/config the sandbox wrote).
            ("exec", as_, tuple(argv), cwd),
            summary,
            detail,
            as_=as_,
            argv=argv,
            # A root command is never approved for the rest of the session.
            allow_session=(as_ == "user"),
            conn=conn,
        )
        log(f"{sandbox}: exec as {as_}: {cmd[:2000]} in {escape(cwd)[:500]}: {why}")
        if not ok:
            return send({"type": "denied", "reason": why})
        full = argv if as_ == "user" else [self.run0, "--user=root", f"--chdir={cwd}", "--", *argv]
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
        with p:
            pump(p.stdout, "stdout")
            t.join()
        send({"type": "exit", "code": p.wait()})

    def op_grant_net(self, sandbox, req, send):
        addr = req.get("addr")
        try:
            net = ipaddress.ip_network(str(addr), strict=False)
        except ValueError:
            return send({"type": "error", "message": "addr must be an IP address or prefix"})
        # An IPv6 scope id ("fe80::1%...") is free text the dialog would show
        # as the broker's own words, and no unit filter takes one.
        if getattr(net.network_address, "scope_id", None):
            return send({"type": "error", "message": "addr must not have a scope id"})
        units = self.sandboxes[sandbox].get("netUnits", [])
        if not units:
            return send({"type": "denied", "reason": "this sandbox's network isn't filtered per sandbox"})
        # A runtime drop-in: it outlives the sandbox, until the host reboots.
        detail = self.with_reason("until the computer restarts (even if the sandbox stops sooner)", req)
        ok, why = self.decide(sandbox, "grant-net", ("net", str(net)), f"connect to {net}", detail)
        log(f"{sandbox}: grant-net {net}: {why}")
        if not ok:
            return send({"type": "denied", "reason": why})
        running = self.running_units(units)
        if not running:
            return send({"type": "denied", "reason": "the sandbox isn't running"})
        # The root attach helper extends the unit's IPAddressAllow= (and does
        # nothing else): the user may not set unit properties themselves.
        attach = self.cfg.get("attach")
        if not attach:
            return send({"type": "error", "message": "no attach helper to update the sandbox's network"})
        for u in running:
            try:
                r = subprocess.run(
                    [attach, "allow-ip", sandbox, u, str(net)],
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
            except subprocess.TimeoutExpired:
                r = subprocess.CompletedProcess([], 1, "", "timed out")
            if r.returncode != 0:
                log(f"allow-ip {u}: {r.stderr.strip()}")
                return send({"type": "error", "message": f"could not update {u}"})
        send({"type": "granted"})

    def op_grant_path(self, sandbox, req, send, conn=None):
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
        mode = "read and change" if write else "read"
        detail = self.with_reason(f"The folder:\n{untrusted(path, 3)}\nuntil the sandbox stops", req)
        ok, why = self.decide(
            sandbox, "grant-path", ("path", path, write), f"{mode} a folder of yours", detail, conn=conn
        )
        log(f"{sandbox}: grant-path {escape(path)[:500]} write={write}: {why}")
        if not ok:
            return send({"type": "denied", "reason": why})
        r = subprocess.run([grant, path, "rw" if write else "ro"], capture_output=True, text=True)
        if r.returncode != 0:
            log(f"grant {path}: {r.stderr.strip()}")
            return send({"type": "error", "message": r.stderr.strip() or "could not grant the folder"})
        send({"type": "granted"})

    def op_camera(self, sandbox, req, send, conn=None):
        prog = self.sandboxes[sandbox].get("camera")
        if not prog:
            return send({"type": "denied", "reason": "this sandbox has no camera access"})
        detail = "until the sandbox stops; meanwhile no other app can use the camera"
        if req.get("reason"):
            detail = self.with_reason(detail, req)
        ok, why = self.decide(sandbox, "camera", ("camera",), "use your camera", detail, conn=conn)
        log(f"{sandbox}: camera: {why}")
        if not ok:
            return send({"type": "denied", "reason": why})
        r = subprocess.run([prog, "attach"], capture_output=True, text=True)
        if r.returncode != 0:
            log(f"{sandbox}: camera: {r.stderr.strip()}")
            return send({"type": "error", "message": r.stderr.strip() or "could not attach the camera"})
        send({"type": "granted"})

    def op_clipboard(self, sandbox, req, send):
        prog = self.sandboxes[sandbox].get("clipboard")
        if not prog:
            return send({"type": "denied", "reason": "this sandbox can't set the clipboard"})
        text = None
        if not req.get("clear"):
            try:
                text = base64.b64decode(req.get("data", ""), validate=True)
            except (ValueError, TypeError):
                return send({"type": "error", "message": "bad clipboard data"})
            if len(text) > MAX_CLIPBOARD:
                return send({"type": "error", "message": "too much text for the clipboard"})
        with self.lock:
            old = self.clips.pop(sandbox, None)
        # wl-copy stays (--foreground) for as long as its text is the
        # selection, and exits, removing its copy of the text, when something
        # else is copied: while it lives, the clipboard is this sandbox's. So
        # a clear is done only then (never by killing it: its temporary file
        # would stay), and a new copy just replaces it.
        if not text:  # cleared (an empty copy is one too)
            if old is not None and old.poll() is None:
                try:
                    subprocess.run([prog, "--clear"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                except (OSError, subprocess.TimeoutExpired) as e:
                    log(f"{sandbox}: clipboard: {e}")
                log(f"{sandbox}: clipboard: cleared")
            return send({"type": "granted"})
        argv = [prog, "--foreground", "--type", "text/plain"]
        if req.get("sensitive"):
            argv.append("--sensitive")
        try:
            p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            p.stdin.write(text)
            p.stdin.close()
        except OSError as e:
            log(f"{sandbox}: clipboard: {e}")
            return send({"type": "error", "message": "could not set the clipboard"})
        try:
            p.wait(0.3)  # it stays unless it couldn't reach the compositor
        except subprocess.TimeoutExpired:
            pass
        else:
            if p.returncode != 0:
                log(f"{sandbox}: clipboard: {scrub(p.stderr.read().decode(errors='replace'))}")
                return send({"type": "error", "message": "could not set the clipboard"})
        threading.Thread(target=self.reap_clip, args=(p,), daemon=True).start()
        with self.lock:
            self.clips[sandbox] = p
        log(f"{sandbox}: clipboard: {len(text)} bytes{' (sensitive)' if req.get('sensitive') else ''}")
        send({"type": "granted"})

    @staticmethod
    def reap_clip(p):
        p.stderr.read()
        p.stderr.close()
        p.wait()

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
            conn=conn,
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
                "exec": lambda sb, r, snd: self.op_exec(sb, r, snd, conn),
                "grant-net": self.op_grant_net,
                "grant-path": lambda sb, r, snd: self.op_grant_path(sb, r, snd, conn),
                "camera": lambda sb, r, snd: self.op_camera(sb, r, snd, conn),
                "clipboard": self.op_clipboard,
                "fido": lambda sb, r, snd: self.op_fido(sb, r, snd, conn),
                "authenticate": lambda sb, r, snd: self.op_authenticate(sb, r, snd, conn),
            }.get(op)
            if fn is None:
                return send({"type": "error", "message": f"unknown op {str(op)[:100]!r}"})
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
            if not self.take_slot(sandbox, "pulse", MAX_PULSE_CONNS):
                log(f"{sandbox}: audio: too many connections")
                conn.close()
                continue

            def run(conn=conn):
                try:
                    PulseFilter(self, sandbox, conn, upstream).run()
                except OSError as e:
                    log(f"{sandbox}: audio: {e}")
                    conn.close()
                finally:
                    self.free_slot(sandbox, "pulse")

            threading.Thread(target=run, daemon=True).start()

    def serve(self, sandbox, s):
        while True:
            conn, _ = s.accept()
            if not self.take_slot(sandbox, "broker", MAX_CONNS):
                log(f"{sandbox}: too many connections")
                try:
                    conn.settimeout(1)
                    conn.sendall(b'{"type": "denied", "reason": "too many requests from this sandbox at once"}\n')
                except OSError:
                    pass
                conn.close()
                continue

            def run(conn=conn):
                try:
                    self.handle(sandbox, conn)
                finally:
                    self.free_slot(sandbox, "broker")

            threading.Thread(target=run, daemon=True).start()


# ── Audio ────────────────────────────────────────────────────────────────────
# PulseAudio's native protocol (pulsecore/native-common.h, pstream.c): packets of
# a 20-byte descriptor (length, channel, offset hi/lo, flags; big-endian u32s)
# and a payload. Channel 0xffffffff is a control packet, a tagstruct starting
# with the command and its tag (both 'L' u32s); any other channel is audio.
PA_DESC = struct.Struct("!IIIII")
PA_CONTROL = 0xFFFFFFFF
PA_INVALID_INDEX = 0xFFFFFFFF
PA_MAX_PACKET = 16 * 1024 * 1024
PA_ERROR, PA_REPLY, PA_AUTH = 0, 2, 8
PA_CREATE_PLAYBACK_STREAM, PA_DELETE_PLAYBACK_STREAM = 3, 4
PA_CREATE_RECORD_STREAM, PA_DELETE_RECORD_STREAM = 5, 6
PA_SET_CLIENT_NAME = 9
PA_PLAYBACK_STREAM_KILLED, PA_RECORD_STREAM_KILLED = 64, 65
PA_UPDATE_RECORD_STREAM_PROPLIST, PA_UPDATE_CLIENT_PROPLIST = 80, 82
PA_ERR_ACCESS = 1
PA_VERSION_MASK = 0xFFFF
# Shared memory can't cross the filter (it forwards no descriptors), so it is
# negotiated away in both directions of AUTH (PA_PROTOCOL_FLAG_SHM, _MEMFD).
PA_PROTOCOL_SHM_FLAGS = 0x80000000 | 0x40000000
# Commands that act on the server or on other clients rather than on the
# client's own streams: refused for every sandbox.
PA_REFUSED = {
    7: "EXIT",
    19: "REMOVE_SAMPLE",  # the sample cache is shared with every client
    36: "SET_SINK_VOLUME",
    38: "SET_SOURCE_VOLUME",
    39: "SET_SINK_MUTE",
    40: "SET_SOURCE_MUTE",
    44: "SET_DEFAULT_SINK",
    45: "SET_DEFAULT_SOURCE",
    48: "KILL_CLIENT",
    51: "LOAD_MODULE",
    52: "UNLOAD_MODULE",
    53: "ADD_AUTOLOAD",
    54: "REMOVE_AUTOLOAD",
    # Even for its own stream: recording is approved for the source it named.
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
# Commands on a stream by its server-wide index (the first 'L' after the tag):
# allowed on the client's own streams (an app's own volume slider), refused on
# every other client's.
PA_OWN_ONLY = {
    37: ("SET_SINK_INPUT_VOLUME", "sink-input"),
    49: ("KILL_SINK_INPUT", "sink-input"),
    50: ("KILL_SOURCE_OUTPUT", "source-output"),
    67: ("MOVE_SINK_INPUT", "sink-input"),
    69: ("SET_SINK_INPUT_MUTE", "sink-input"),
    98: ("SET_SOURCE_OUTPUT_VOLUME", "source-output"),
    99: ("SET_SOURCE_OUTPUT_MUTE", "source-output"),
}
PA_STREAM_KIND = {
    PA_CREATE_PLAYBACK_STREAM: "sink-input",
    PA_DELETE_PLAYBACK_STREAM: "sink-input",
    PA_PLAYBACK_STREAM_KILLED: "sink-input",
    PA_CREATE_RECORD_STREAM: "source-output",
    PA_DELETE_RECORD_STREAM: "source-output",
    PA_RECORD_STREAM_KILLED: "source-output",
}
PA_MAX_PENDING_RECORDS = 4  # record streams of one connection awaiting a decision


def pa_routes(props):
    """Whether a proplist picks what a stream connects to. PipeWire's pulse
    server copies client and stream properties onto its streams, where
    target.object, node.target or stream.capture.sink choose the source over
    the request's own fields (another app's stream, a sink's monitor)."""
    return any(
        k.startswith(("target.", "stream.", "object.", "port."))
        or k in ("node.target", "node.link-group", "node.autoconnect", "media.class")
        for k in props
    )


class PaTags:
    """A reader for a tagstruct, from `offset` on (pulsecore/tagstruct.c).
    Malformed input raises ValueError."""

    def __init__(self, data, offset=10):
        self.data = data
        self.i = offset

    def take(self, n):
        if self.i + n > len(self.data):
            raise ValueError("truncated tagstruct")
        b = self.data[self.i : self.i + n]
        self.i += n
        return b

    def expect(self, tag):
        if self.take(1) != tag:
            raise ValueError(f"expected tag {tag!r}")

    def u32(self):
        self.expect(b"L")
        return struct.unpack("!I", self.take(4))[0]

    def boolean(self):
        t = self.take(1)
        if t not in (b"0", b"1"):
            raise ValueError("expected a boolean")
        return t == b"1"

    def string(self):
        t = self.take(1)
        if t == b"N":
            return None
        if t != b"t":
            raise ValueError("expected a string")
        end = self.data.find(b"\0", self.i)
        if end < 0:
            raise ValueError("unterminated string")
        s = self.data[self.i : end].decode("utf-8", "replace")
        self.i = end + 1
        return s

    def sample_spec(self):
        self.expect(b"a")
        self.take(6)  # format, channels, rate

    def channel_map(self):
        self.expect(b"m")
        self.take(self.take(1)[0])

    def proplist(self):
        """The keys of a proplist ('P', then key, length, value until a null key)."""
        self.expect(b"P")
        keys = []
        while True:
            k = self.string()
            if k is None:
                return keys
            n = self.u32()
            self.expect(b"x")
            if struct.unpack("!I", self.take(4))[0] != n:
                raise ValueError("proplist length mismatch")
            self.take(n)
            keys.append(k)


def pa_record_request(payload, version):
    """(source index, source name, direct_on_input, proplist keys) of a
    CREATE_RECORD_STREAM, or None when it doesn't parse (pulse/stream.c
    create_stream; the protocol version decides which fields are there)."""
    if version is None:
        return None
    r = PaTags(payload)
    try:
        if version < 13:
            r.string()  # stream name
        r.sample_spec()
        r.channel_map()
        index = r.u32()
        name = r.string()
        r.u32()  # maxlength
        r.boolean()  # corked
        r.u32()  # fragsize
        keys, direct = [], PA_INVALID_INDEX
        if version >= 12:
            for _ in range(7):  # no_remap … variable_rate
                r.boolean()
        if version >= 13:
            r.boolean()  # peak_detect
            r.boolean()  # adjust_latency
            keys = r.proplist()
            direct = r.u32()
        return index, name, direct, keys
    except ValueError:
        return None


def pa_record_kind(req, client_routes=False):
    """What a record request would hear, conservatively, as (kind, source,
    named): ("mic", None, True) only for the default source chosen by nothing
    but the server's default; else "monitor" for the sound other apps play (a
    monitor, another app's stream, or a source the filter can't name), or
    "device" for a source the app named, which may be a monitor under another
    name (PipeWire records a sink named as a source). `named` is whether the
    source is a name, the same one next time (an index can be reused)."""
    if req is None:
        return "monitor", "a source the request doesn't let the broker identify", False
    index, name, direct, keys = req
    if direct != PA_INVALID_INDEX:
        return "monitor", f"the sound of one stream of another app (#{direct})", False
    # PipeWire takes a name that starts with a number (atoi) as an index.
    numbered = name is not None and name.lstrip()[:1] in ("", "+", "-", *"0123456789")
    if index != PA_INVALID_INDEX or numbered:
        # An index can't be resolved to a source without asking the server,
        # so it may be a monitor.
        return "monitor", f"the source numbered {name if numbered else index}", False
    if client_routes or pa_routes(keys):
        return "monitor", "a source the app picks through PipeWire stream properties", False
    if name is None or name == "@DEFAULT_SOURCE@":
        return "mic", None, True
    if name == "@DEFAULT_MONITOR@" or name.endswith(".monitor"):
        return "monitor", name, True
    return "device", name, True


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


def pa_u32(payload, offset):
    """The 'L' u32 at payload[offset:], or None."""
    if payload[offset : offset + 1] != b"L" or len(payload) < offset + 5:
        return None
    return struct.unpack("!I", payload[offset + 1 : offset + 5])[0]


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


class PulseFilter:
    """One sandbox client's connection to the user's PulseAudio server.

    It follows the streams the client creates (the server's reply to each
    CREATE_*_STREAM names its channel and index, until deleted or killed), so
    commands on a stream by index pass only for the client's own."""

    def __init__(self, broker, sandbox, client, upstream_path):
        self.broker = broker
        self.sandbox = sandbox
        self.client = client
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
        self.server.connect(upstream_path)
        self.to_client = threading.Lock()
        self.to_server = threading.Lock()
        self.auth_tag = None
        self.client_version = None
        self.version = None  # negotiated in AUTH
        self.mic = broker.sandboxes[sandbox].get("audio") == "microphone"
        self.state = threading.Lock()
        self.pending = {}  # tag of a CREATE_*_STREAM (records from arrival) -> stream kind
        self.streams = {}  # (kind, channel) -> server-wide index
        self.recording = 0  # record requests awaiting a decision
        self.client_routes = False  # the client's proplist picked a target

    def send_client(self, data):
        with self.to_client:
            self.client.sendall(data)

    def send_server(self, data):
        with self.to_server:
            self.server.sendall(data)

    def owns(self, kind, index):
        with self.state:
            return any(k == kind and i == index for (k, _), i in self.streams.items())

    def forget(self, kind, channel):
        with self.state:
            self.streams.pop((kind, channel), None)

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
                    payload = self.server_control(payload)
                self.send_client(PA_DESC.pack(len(payload), *desc[1:]) + payload)
        except (OSError, ValueError):
            pass
        finally:
            try:
                self.client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def server_control(self, payload):
        cmd = pa_command(payload)
        if cmd is None:
            return payload
        command, tag = cmd
        if command == PA_REPLY and tag == self.auth_tag:
            server_version = pa_u32(payload, 10)
            if server_version is not None and self.client_version is not None:
                self.version = min(server_version & PA_VERSION_MASK, self.client_version)
            return pa_clear_shm(payload, 10)
        if command in (PA_REPLY, PA_ERROR):
            with self.state:
                kind = self.pending.pop(tag, None)
                channel, index = pa_u32(payload, 10), pa_u32(payload, 15)
                # A playback stream's reply goes on with `missing` (an upload
                # stream's, say, ends after channel and length).
                shaped = kind != "sink-input" or pa_u32(payload, 20) is not None
                if kind and command == PA_REPLY and channel is not None and index is not None and shaped:
                    self.streams[(kind, channel)] = index
        elif command in (PA_PLAYBACK_STREAM_KILLED, PA_RECORD_STREAM_KILLED):
            self.forget(PA_STREAM_KIND[command], pa_u32(payload, 10))
        return payload

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
                with self.state:
                    # A reply is matched to a stream by its tag: another
                    # command can't share one still waiting (its reply could
                    # pass for the stream's, with another client's index).
                    reused = tag in self.pending
                refused = "a tag still in use" if reused else self.refuse(command, payload)
                if refused:
                    log(f"{self.sandbox}: audio: refused {refused}")
                    self.send_client(pa_error(tag))
                    continue
                if command == PA_AUTH:
                    self.auth_tag = tag
                    v = pa_u32(payload, 10)
                    self.client_version = None if v is None else v & PA_VERSION_MASK
                    payload = pa_clear_shm(payload, 10)
                elif command == PA_CREATE_RECORD_STREAM:
                    with self.state:
                        busy = self.recording >= PA_MAX_PENDING_RECORDS
                        if not busy:
                            self.recording += 1
                            self.pending[tag] = "source-output"
                    if busy:
                        log(f"{self.sandbox}: audio: refused a record stream (too many waiting)")
                        self.send_client(pa_error(tag))
                        continue
                    # Decided off this thread, so the prompt doesn't stall the
                    # connection's playback meanwhile.
                    threading.Thread(target=self.record, args=(tag, payload), daemon=True).start()
                    continue
                elif command == PA_CREATE_PLAYBACK_STREAM:
                    with self.state:
                        self.pending[tag] = "sink-input"
                elif command in (PA_DELETE_PLAYBACK_STREAM, PA_DELETE_RECORD_STREAM):
                    self.forget(PA_STREAM_KIND[command], pa_u32(payload, 10))
                self.send_server(pa_packet(payload))
        except (OSError, ValueError):
            pass

    def refuse(self, command, payload):
        """Why a client command is refused (its name), or None to pass it."""
        if command in PA_REFUSED:
            return PA_REFUSED[command]
        if command in PA_OWN_ONLY:
            name, kind = PA_OWN_ONLY[command]
            index = pa_u32(payload, 10)
            if index is None or not self.owns(kind, index):
                return f"{name} on another client's stream"
            return None
        if command in (PA_SET_CLIENT_NAME, PA_UPDATE_CLIENT_PROPLIST):
            # Later streams inherit the client's properties (PipeWire): one
            # that picks a target makes every later recording "other sound".
            r = PaTags(payload)
            try:
                if command == PA_UPDATE_CLIENT_PROPLIST:
                    r.u32()  # update mode
                routes = pa_routes(r.proplist())
            except ValueError:
                routes = command == PA_UPDATE_CLIENT_PROPLIST or payload[10:11] == b"P"
            if routes:
                with self.state:
                    # Not while a recording is asked about or open: it was
                    # classified (and the user asked) without them, and the
                    # server would see them before the record request.
                    recording = (
                        self.recording
                        or "source-output" in self.pending.values()
                        or any(k == "source-output" for k, _ in self.streams)
                    )
                    if not recording:
                        self.client_routes = True
                if recording:
                    return "client properties that pick a source while recording"
            return None
        if command == PA_UPDATE_RECORD_STREAM_PROPLIST:
            r = PaTags(payload)
            try:
                r.u32()  # channel
                r.u32()  # update mode
                routes = pa_routes(r.proplist())
            except ValueError:
                routes = True
            if routes:
                return "UPDATE_RECORD_STREAM_PROPLIST that picks a different source"
        return None

    def record(self, tag, payload):
        try:
            kind, source, named = pa_record_kind(pa_record_request(payload, self.version), self.client_routes)
            if not self.mic:
                ok, why = False, "this sandbox has no microphone access"
            elif kind == "mic":
                ok, why = self.broker.decide(
                    self.sandbox, "microphone", ("microphone", "default"), "use your microphone",
                    "until you close the app or the answer's session expires",
                )
            else:
                what = (
                    "record the sound other apps play"
                    if kind == "monitor"
                    else "record from a sound device the app chose (it may be the sound other apps play)"
                )
                ok, why = self.broker.decide(
                    self.sandbox, "microphone", ("microphone", kind, source), what,
                    Broker.with_reason(f"The source:\n{untrusted(source, 2)}", {}),
                    # A source by index (or a stream) can't be told apart from
                    # a later one with the same number.
                    allow_session=named,
                )
            log(f"{self.sandbox}: audio: record {kind} {escape(source or '(default source)')[:300]}: {why}")
            if ok:
                self.send_server(pa_packet(payload))
            else:
                with self.state:
                    self.pending.pop(tag, None)
                self.send_client(pa_error(tag))
        except OSError:
            pass
        finally:
            with self.state:
                self.recording -= 1


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
    # A bytearray grows in place: a payload trickled in small pieces costs
    # linear time, not a copy of all of it per piece.
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(min(n - len(buf), 1 << 20))
        if not chunk:
            return None
        buf += chunk
    return bytes(buf)


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
