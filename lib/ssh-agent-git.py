"""ssh-agent-git: a filtered view of the user's ssh-agent, for git only.

Socket-activated per connection (systemd Accept=yes, stdin = the client);
relays to the real agent at argv[1]. A sandbox given this socket instead of the
agent's can do what git needs and nothing more:

- list keys (SSH_AGENTC_REQUEST_IDENTITIES);
- sign an SSH user-auth request whose user name is "git" (fetch/push to
  GitHub, Gitea, ...: every forge logs in as "git"). The signed blob carries
  the user name (RFC 4252 7), and a server only accepts the signature for that
  user, so it can't log in as jrt anywhere: with the plain agent socket, ssh
  to the host's own sshd as jrt was a way out of the sandbox;
- sign an SSHSIG blob in the "git" namespace (commit/tag signing,
  gpg.format = ssh). SSHSIG blobs start with a fixed preamble, so they can't
  double as an auth signature (PROTOCOL.sshsig).

Everything else (adding/removing keys, lock, extensions incl. session-bind,
other SSHSIG namespaces) gets SSH_AGENT_FAILURE without reaching the agent.
"""

import socket
import struct
import sys

FAILURE = 5
REQUEST_IDENTITIES = 11
SIGN_REQUEST = 13
USERAUTH_REQUEST = 50
MAX_LEN = 256 * 1024  # OpenSSH's own agent message cap
SSHSIG_MAGIC = b"SSHSIG"
ALLOWED_USERS = {b"git"}
ALLOWED_NAMESPACES = {b"git"}


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def read_msg(sock):
    head = read_exact(sock, 4)
    if head is None:
        return None
    (n,) = struct.unpack(">I", head)
    if n == 0 or n > MAX_LEN:
        raise ValueError("bad message length")
    body = read_exact(sock, n)
    if body is None:
        return None
    return body


def send_msg(sock, body):
    sock.sendall(struct.pack(">I", len(body)) + body)


def take_string(buf, off):
    """SSH wire string at buf[off:]: (bytes, next offset). Raises on overrun."""
    if off + 4 > len(buf):
        raise ValueError("short string length")
    (n,) = struct.unpack_from(">I", buf, off)
    off += 4
    if off + n > len(buf):
        raise ValueError("short string")
    return buf[off : off + n], off + n


def sign_allowed(payload):
    """payload = string key_blob, string data, uint32 flags."""
    _key, off = take_string(payload, 0)
    data, off = take_string(payload, off)
    if off + 4 != len(payload):
        return False
    if data.startswith(SSHSIG_MAGIC):
        namespace, _ = take_string(data, len(SSHSIG_MAGIC))
        return namespace in ALLOWED_NAMESPACES
    # User auth: string session_id, byte 50, string user, string service, ...
    _session, off = take_string(data, 0)
    if off >= len(data) or data[off] != USERAUTH_REQUEST:
        return False
    user, off = take_string(data, off + 1)
    service, _ = take_string(data, off)
    return user in ALLOWED_USERS and service == b"ssh-connection"


def allowed(msg):
    kind = msg[0]
    if kind == REQUEST_IDENTITIES:
        return len(msg) == 1
    if kind == SIGN_REQUEST:
        try:
            return sign_allowed(msg[1:])
        except ValueError:
            return False
    return False


def main():
    upstream_path = sys.argv[1]
    client = socket.socket(fileno=sys.stdin.fileno())
    upstream = None
    while True:
        try:
            msg = read_msg(client)
        except ValueError:
            return
        if msg is None:
            return
        if not allowed(msg):
            send_msg(client, bytes([FAILURE]))
            continue
        if upstream is None:
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            upstream.connect(upstream_path)
        send_msg(upstream, msg)
        reply = read_msg(upstream)
        if reply is None:
            return
        send_msg(client, reply)


if __name__ == "__main__":
    main()
