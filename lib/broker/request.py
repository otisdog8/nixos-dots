"""sbx-request: ask the sandbox broker (sbx-broker) for something outside the sandbox.

  sbx-request exec [--root] [--reason TEXT] [--] COMMAND [ARG...]
      Run COMMAND outside the sandbox, as the user (or as root, with --root),
      after the user approves it. Output streams back; the exit status is
      COMMAND's. The working directory is carried over when it exists on the host.
  sbx-request grant-path [--write] [--reason TEXT] PATH
      Ask for a folder (read-only, or read-write with --write) while running.
  sbx-request grant-net [--reason TEXT] ADDRESS[/PREFIX]
      Ask to reach an address the sandbox's network policy blocks.

The broker socket is /run/sbx/broker.sock in sandboxes (SBX_BROKER overrides).
Exit status 126 when the request is denied, 125 on errors.
"""

import argparse
import base64
import json
import os
import socket
import sys

SOCKET = os.environ.get("SBX_BROKER", "/run/sbx/broker.sock")


def main():
    ap = argparse.ArgumentParser(prog="sbx-request")
    sub = ap.add_subparsers(dest="op", required=True)
    e = sub.add_parser("exec")
    e.add_argument("--root", action="store_true")
    e.add_argument("--reason", default="")
    e.add_argument("argv", nargs=argparse.REMAINDER)
    p = sub.add_parser("grant-path")
    p.add_argument("--write", action="store_true")
    p.add_argument("--reason", default="")
    p.add_argument("path")
    n = sub.add_parser("grant-net")
    n.add_argument("--reason", default="")
    n.add_argument("addr")
    a = ap.parse_args()

    if a.op == "exec":
        argv = a.argv[1:] if a.argv[:1] == ["--"] else a.argv
        if not argv:
            ap.error("exec needs a command")
        req = {
            "op": "exec",
            "as": "root" if a.root else "user",
            "argv": argv,
            "cwd": os.getcwd(),
            "reason": a.reason,
        }
    elif a.op == "grant-path":
        req = {
            "op": "grant-path",
            "path": os.path.abspath(a.path),
            "write": a.write,
            "reason": a.reason,
        }
    else:
        req = {"op": "grant-net", "addr": a.addr, "reason": a.reason}

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(SOCKET)
    except OSError as err:
        print(f"sbx-request: no broker at {SOCKET}: {err.strerror}", file=sys.stderr)
        return 125
    s.sendall((json.dumps(req) + "\n").encode())
    f = s.makefile("rb")
    for line in f:
        msg = json.loads(line)
        t = msg.get("type")
        if t == "stdout":
            sys.stdout.buffer.write(base64.b64decode(msg["data"]))
            sys.stdout.buffer.flush()
        elif t == "stderr":
            sys.stderr.buffer.write(base64.b64decode(msg["data"]))
            sys.stderr.buffer.flush()
        elif t == "exit":
            return int(msg["code"]) if msg["code"] >= 0 else 128 - msg["code"]
        elif t == "granted":
            print("sbx-request: granted", file=sys.stderr)
            return 0
        elif t == "denied":
            print(f"sbx-request: denied ({msg.get('reason', '')})", file=sys.stderr)
            return 126
        else:
            print(f"sbx-request: {msg.get('message', 'error')}", file=sys.stderr)
            return 125
    print("sbx-request: the broker closed the connection", file=sys.stderr)
    return 125


if __name__ == "__main__":
    sys.exit(main())
