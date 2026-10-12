"""A virtual FIDO security key in a sandbox VM, backed by the host's real one.

Runs as root in the guest. Creates a uhid HID device with the standard CTAPHID
report descriptor (so libfido2, browsers and ssh see an ordinary USB security
key), and relays its 64-byte reports through the sandbox broker's "fido" op
(lib/broker/broker.py), reached over the VM's relay socket. The broker asks the
user before the first use and opens whichever key is plugged in at that moment,
so keys can come and go while the VM runs.

  sbx-fido-guest --broker /run/sbx/broker.sock
"""

import argparse
import errno
import json
import os
import socket
import struct
import sys
import threading
import time

REPORT = 64
# struct uhid_event (linux/uhid.h, packed): u32 type + the largest request.
UHID_EVENT_SIZE = 4 + 4372
UHID_START, UHID_STOP, UHID_OPEN, UHID_CLOSE, UHID_OUTPUT = 2, 3, 4, 5, 6
UHID_GET_REPORT, UHID_GET_REPORT_REPLY = 9, 10
UHID_CREATE2, UHID_INPUT2 = 11, 12
UHID_SET_REPORT, UHID_SET_REPORT_REPLY = 13, 14
BUS_USB = 0x03

# Usage Page (FIDO), Usage (CTAPHID), Collection (Application):
#   64 bytes in (Usage 0x20), 64 bytes out (Usage 0x21).
DESCRIPTOR = bytes(
    [0x06, 0xD0, 0xF1, 0x09, 0x01, 0xA1, 0x01]
    + [0x09, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x81, 0x02]
    + [0x09, 0x21, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02]
    + [0xC0]
)

CTAP_ERROR = 0xBF  # CTAPHID_ERROR with the initialization-packet bit
CTAP_ERR_OTHER = 0x7F
# After the user (or a rule) refuses, answer with errors for a while instead of
# prompting again on every packet.
DENIED_BACKOFF = 30


def log(msg):
    print(f"sbx-fido-guest: {msg}", file=sys.stderr, flush=True)


def uhid_create(fd):
    req = struct.pack(
        "<128s64s64sHHIIII4096s",
        b"sbx security key (host)",
        b"sbx-fido",
        b"",
        len(DESCRIPTOR),
        BUS_USB,
        0x1209,  # pid.codes test vendor
        0xF1D0,
        0x0100,
        0,
        DESCRIPTOR,
    )
    os.write(fd, struct.pack("<I", UHID_CREATE2) + req)


def uhid_input(fd, report):
    os.write(fd, struct.pack("<IH", UHID_INPUT2, len(report)) + report.ljust(4096, b"\0"))


class Device:
    def __init__(self, broker):
        self.broker = broker
        self.fd = os.open("/dev/uhid", os.O_RDWR | os.O_CLOEXEC)
        self.conn = None
        self.denied_until = 0
        self.lock = threading.Lock()
        uhid_create(self.fd)
        log("virtual security key created")

    def error_reply(self, pkt):
        """Fail the app's request at once (instead of letting it time out)."""
        uhid_input(self.fd, pkt[:4] + bytes([CTAP_ERROR, 0, 1, CTAP_ERR_OTHER]))

    def connect(self):
        if time.monotonic() < self.denied_until:
            return None
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
        try:
            s.connect(self.broker)
            s.sendall(b'{"op": "fido"}\n')
            line = b""
            while not line.endswith(b"\n"):
                c = s.recv(1)
                if not c:
                    raise ConnectionError("the broker closed the connection")
                line += c
            answer = json.loads(line)
        except (OSError, ValueError) as e:
            log(f"broker: {e}")
            s.close()
            return None
        if answer.get("type") != "granted":
            log(f"not allowed: {answer.get('reason') or answer.get('message')}")
            self.denied_until = time.monotonic() + DENIED_BACKOFF
            s.close()
            return None
        threading.Thread(target=self.from_host, args=(s,), daemon=True).start()
        log("connected to the host's security key")
        return s

    def from_host(self, s):
        buf = b""
        try:
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                buf += chunk
                while len(buf) >= REPORT:
                    uhid_input(self.fd, buf[:REPORT])
                    buf = buf[REPORT:]
        except OSError:
            pass
        with self.lock:
            if self.conn is s:
                self.conn = None
        s.close()
        log("host connection closed (key unplugged or VM session over)")

    def output(self, pkt):
        with self.lock:
            if self.conn is None:
                self.conn = self.connect()
            conn = self.conn
        if conn is None:
            self.error_reply(pkt)
            return
        try:
            conn.sendall(pkt)
        except OSError:
            with self.lock:
                self.conn = None
            self.error_reply(pkt)

    def run(self):
        while True:
            ev = os.read(self.fd, UHID_EVENT_SIZE)
            (kind,) = struct.unpack_from("<I", ev)
            if kind == UHID_OUTPUT:
                data = ev[4 : 4 + 4096]
                (size,) = struct.unpack_from("<H", ev, 4 + 4096)
                report = data[:size]
                # hidraw writes carry the report number first (0: no report IDs).
                if size == REPORT + 1 and report[0] == 0:
                    report = report[1:]
                self.output(report[:REPORT].ljust(REPORT, b"\0"))
            elif kind == UHID_GET_REPORT:
                (rid,) = struct.unpack_from("<I", ev, 4)
                os.write(
                    self.fd,
                    struct.pack("<IIHH", UHID_GET_REPORT_REPLY, rid, errno.EIO, 0).ljust(UHID_EVENT_SIZE, b"\0"),
                )
            elif kind == UHID_SET_REPORT:
                (rid,) = struct.unpack_from("<I", ev, 4)
                os.write(self.fd, struct.pack("<IIH", UHID_SET_REPORT_REPLY, rid, errno.EIO).ljust(UHID_EVENT_SIZE, b"\0"))
            elif kind == UHID_CLOSE:
                # The last app closed the device: let go of the host's key.
                with self.lock:
                    conn, self.conn = self.conn, None
                if conn is not None:
                    try:
                        conn.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass


def main():
    ap = argparse.ArgumentParser(prog="sbx-fido-guest")
    ap.add_argument("--broker", required=True)
    a = ap.parse_args()
    Device(a.broker).run()


if __name__ == "__main__":
    main()
