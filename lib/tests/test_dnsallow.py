"""sbx-dnsallow's IP filter updates, with systemctl mocked.

    python3 -I -m unittest discover -s lib/tests -p test_dnsallow.py
"""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest

DNSALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dnsallow.py")
spec = importlib.util.spec_from_file_location("dnsallow", DNSALLOW)
dnsallow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dnsallow)

A, AAAA = 1, 28


def answer(name, *addrs):
    return {
        "state": "success",
        "question": [{"name": name}],
        "answer": [{"rr": {"key": {"type": AAAA if ":" in a else A}, "address": a}} for a in addrs],
    }


class FakeAllower(dnsallow.Allower):
    """Records systemctl calls; `units` are the loaded ones (others: not
    found); `fail` makes set-property fail; `shows` answers `show`."""

    def __init__(self, cfg, units=(), clock=None):
        self.clock = clock or [1000.0]
        super().__init__(cfg, now=lambda: self.clock[0])
        self.loaded = set(units)
        self.calls = []
        self.fail = False
        self.shows = {}

    def run(self, *args):
        self.calls.append(list(args))
        ok = lambda out="": subprocess.CompletedProcess(args, 0, out, "")
        if args[0] == "set-property":
            unit = args[2]
            if unit not in self.loaded:
                return subprocess.CompletedProcess(args, 1, "", f"Failed: Unit {unit} not found.")
            if self.fail:
                return subprocess.CompletedProcess(args, 1, "", "Access denied")
            return ok()
        if args[0] == "list-units":
            pat = args[-1]
            import fnmatch

            return ok("".join(f"{u} loaded active running x\n" for u in sorted(self.loaded) if fnmatch.fnmatchcase(u, pat)))
        if args[0] == "show":
            return ok(self.shows.get(args[-1], "LoadState=not-found\n"))
        raise AssertionError(args)

    def sets(self):
        return {c[2]: c[3:] for c in self.calls if c[0] == "set-property"}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.tmp.name, "learned.json")
        self.cfg = {
            "systemctl": "systemctl",
            "local": ["10.0.0.0/8", "fd00::/8", "127.0.0.0/8"],
            "localFile": None,
            "state": self.state,
            "grants": os.path.join(self.tmp.name, "grants"),
            "rules": [
                {
                    "units": ["agent-vm-net.service"],
                    "names": ["broker.example.com", "*.cdn.example"],
                    "deny": ["203.0.113.0/24"],
                    "allow": ["127.0.0.53", "198.51.100.7"],
                },
                {
                    "units": ["vm-x-net@*.service"],
                    "names": ["api.example.org"],
                    "deny": [],
                    "allow": ["127.0.0.53"],
                },
            ],
        }

    def tearDown(self):
        self.tmp.cleanup()

    def allower(self, **kw):
        kw.setdefault("units", ["agent-vm-net.service", "vm-x-net@a.service"])
        return FakeAllower(self.cfg, **kw)


class FullList(Base):
    def test_every_update_writes_reset_static_and_learned(self):
        a = self.allower()
        a.handle(answer("broker.example.com", "192.0.2.1"))
        self.assertEqual(
            a.sets()["agent-vm-net.service"],
            ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 198.51.100.7 192.0.2.1"],
        )
        a.calls.clear()
        a.clock[0] += 5
        a.handle(answer("x.cdn.example", "192.0.2.2", "2001:db8::2"))
        self.assertEqual(
            a.sets()["agent-vm-net.service"],
            ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 198.51.100.7 192.0.2.1 192.0.2.2 2001:db8::2"],
        )

    def test_nothing_new_writes_nothing(self):
        a = self.allower()
        a.handle(answer("broker.example.com", "192.0.2.1"))
        a.calls.clear()
        a.handle(answer("broker.example.com", "192.0.2.1"))
        self.assertEqual(a.sets(), {})

    def test_local_denied_and_unmatched_are_not_opened(self):
        a = self.allower()
        a.handle(answer("broker.example.com", "10.1.2.3", "203.0.113.9", "::ffff:127.0.0.1"))
        a.handle(answer("other.example.com", "192.0.2.50"))
        a.handle(answer("cdn.example", "192.0.2.51"))  # the wildcard's own name
        self.assertEqual(a.sets(), {})

    def test_glob_rule_reaches_its_active_instances_only(self):
        a = self.allower(units=["agent-vm-net.service", "vm-x-net@a.service", "vm-x-net@b.service"])
        a.handle(answer("api.example.org", "192.0.2.9"))
        self.assertEqual(set(a.sets()), {"vm-x-net@a.service", "vm-x-net@b.service"})
        self.assertEqual(a.sets()["vm-x-net@a.service"], ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 192.0.2.9"])

    def test_failed_write_is_retried(self):
        a = self.allower()
        a.fail = True
        a.handle(answer("broker.example.com", "192.0.2.1"))
        self.assertNotIn("192.0.2.1", a.learned.get("agent-vm-net.service", {}))
        a.fail = False
        a.calls.clear()
        a.handle(answer("broker.example.com", "192.0.2.1"))
        self.assertIn("IPAddressAllow=127.0.0.53 198.51.100.7 192.0.2.1", a.sets()["agent-vm-net.service"])

    def test_expiry_and_cap(self):
        a = self.allower()
        a.handle(answer("broker.example.com", "192.0.2.1"))
        a.clock[0] += dnsallow.MAX_AGE + 1
        a.handle(answer("broker.example.com", "192.0.2.2"))
        self.assertEqual(
            a.sets()["agent-vm-net.service"][-1], "IPAddressAllow=127.0.0.53 198.51.100.7 192.0.2.2"
        )
        old = dnsallow.MAX_PER_UNIT
        dnsallow.MAX_PER_UNIT = 2
        try:
            for i in range(3, 6):
                a.clock[0] += 1
                a.handle(answer("broker.example.com", f"192.0.2.{i}"))
            self.assertEqual(sorted(a.learned["agent-vm-net.service"]), ["192.0.2.4", "192.0.2.5"])
        finally:
            dnsallow.MAX_PER_UNIT = old


class Startup(Base):
    def test_writes_static_list_for_every_managed_unit(self):
        a = self.allower()
        a.startup()
        self.assertEqual(
            a.sets(),
            {
                "agent-vm-net.service": ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 198.51.100.7"],
                "vm-x-net@a.service": ["IPAddressAllow=", "IPAddressAllow=127.0.0.53"],
            },
        )

    def test_unloaded_glob_instance_with_a_drop_in_is_covered(self):
        a = self.allower()
        control = os.path.join(self.tmp.name, "system.control") + "/"
        os.makedirs(control + "vm-x-net@old.service.d")
        a.loaded.add("vm-x-net@old.service")
        a.calls.clear()
        orig = dnsallow.CONTROL_DIRS
        dnsallow.CONTROL_DIRS = (control,)
        try:
            a.startup()
        finally:
            dnsallow.CONTROL_DIRS = orig
        self.assertIn("vm-x-net@old.service", a.sets())

    def test_learned_addresses_survive_a_restart_and_static_changes(self):
        a = self.allower()
        a.startup()
        a.handle(answer("broker.example.com", "192.0.2.1"))
        a.handle(answer("api.example.org", "192.0.2.9"))
        with open(self.state) as f:
            self.assertIn("192.0.2.1", json.load(f)["units"]["agent-vm-net.service"])

        # A rebuild: one static entry removed, one added.
        self.cfg["rules"][0]["allow"] = ["127.0.0.53", "198.51.100.8"]
        b = self.allower()
        b.startup()
        self.assertEqual(
            b.sets()["agent-vm-net.service"],
            ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 198.51.100.8 192.0.2.1"],
        )
        self.assertEqual(
            b.sets()["vm-x-net@a.service"], ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 192.0.2.9"]
        )

    def test_learned_addresses_no_longer_allowed_are_dropped(self):
        a = self.allower()
        a.handle(answer("broker.example.com", "192.0.2.1"))
        a.handle(answer("x.cdn.example", "192.0.2.2"))
        a.handle(answer("y.cdn.example", "192.0.2.3"))
        self.cfg["rules"][0]["names"] = ["*.cdn.example"]  # broker.example.com removed
        self.cfg["rules"][0]["deny"] = ["192.0.2.3/32"]  # and y's answer now denied
        b = self.allower()
        b.startup()
        self.assertEqual(
            b.sets()["agent-vm-net.service"],
            ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 198.51.100.7 192.0.2.2"],
        )

    def test_unit_no_longer_managed_goes_back_to_its_unit_files(self):
        a = self.allower()
        a.handle(answer("api.example.org", "192.0.2.9"))
        unit_file = os.path.join(self.tmp.name, "vm-x-net@a.service")
        drop_in = os.path.join(self.tmp.name, "overrides.conf")
        with open(unit_file, "w") as f:
            f.write("[Service]\nIPAddressAllow=192.0.2.200\nIPAddressDeny=any\n")
        with open(drop_in, "w") as f:
            f.write("[Service]\nIPAddressAllow=\nIPAddressAllow=127.0.0.53 198.51.100.1\n")
        del self.cfg["rules"][1]  # the VM lost its allowNames
        b = self.allower()
        b.shows["vm-x-net@a.service"] = (
            f"LoadState=loaded\nFragmentPath={unit_file}\n"
            f"DropInPaths={drop_in} /run/systemd/system.control/vm-x-net@a.service.d/50-IPAddressAllow.conf\n"
        )
        b.startup()
        self.assertEqual(
            b.sets()["vm-x-net@a.service"], ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 198.51.100.1"]
        )
        with open(self.state) as f:
            self.assertNotIn("vm-x-net@a.service", json.load(f)["units"])

    def test_missing_unit_is_skipped(self):
        a = self.allower(units=[])
        a.startup()
        self.assertEqual(a.learned, {})

    def test_corrupt_state_starts_empty(self):
        with open(self.state, "w") as f:
            f.write("{nope")
        a = self.allower()
        a.startup()
        self.assertEqual(a.sets()["agent-vm-net.service"], ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 198.51.100.7"])


class Grants(Base):
    def grant(self, unit, *nets):
        os.makedirs(self.cfg["grants"], exist_ok=True)
        path = os.path.join(self.cfg["grants"], "grants.json")
        try:
            with open(path) as f:
                units = json.load(f)["units"]
        except FileNotFoundError:
            units = {}
        units.setdefault(unit, []).extend(nets)
        with open(path, "w") as f:
            json.dump({"units": units}, f)

    def test_broker_grants_are_in_every_write(self):
        self.grant("agent-vm-net.service", "192.0.2.77/32")
        self.grant("vm-x-net@b.service", "192.0.2.88/32")  # another unit's
        a = self.allower()
        a.startup()
        self.assertEqual(
            a.sets()["agent-vm-net.service"],
            ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 198.51.100.7 192.0.2.77/32"],
        )
        a.calls.clear()
        a.handle(answer("broker.example.com", "192.0.2.1"))
        self.assertEqual(
            a.sets()["agent-vm-net.service"],
            ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 198.51.100.7 192.0.2.1 192.0.2.77/32"],
        )

    def test_grants_stay_when_a_unit_is_no_longer_managed(self):
        a = self.allower()
        a.startup()
        self.grant("vm-x-net@a.service", "192.0.2.88/32")
        unit_file = os.path.join(self.tmp.name, "u.service")
        with open(unit_file, "w") as f:
            f.write("[Service]\nIPAddressAllow=127.0.0.53\n")
        del self.cfg["rules"][1]
        b = self.allower()
        b.shows["vm-x-net@a.service"] = f"LoadState=loaded\nFragmentPath={unit_file}\nDropInPaths=\n"
        b.startup()
        self.assertEqual(
            b.sets()["vm-x-net@a.service"], ["IPAddressAllow=", "IPAddressAllow=127.0.0.53 192.0.2.88/32"]
        )

    def test_write_holds_the_grants_lock(self):
        import fcntl

        os.makedirs(self.cfg["grants"])
        lock = os.path.join(self.cfg["grants"], "lock")
        open(lock, "w").close()
        a = self.allower()
        seen = []
        run = a.run

        def checking_run(*args):
            if args[0] == "set-property":
                fd = os.open(lock, os.O_RDONLY)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    seen.append("free")
                except BlockingIOError:
                    seen.append("held")
                finally:
                    os.close(fd)
            return run(*args)

        a.run = checking_run
        a.handle(answer("broker.example.com", "192.0.2.1"))
        self.assertEqual(seen, ["held"])


class Limits(Base):
    def test_long_lists_are_split_into_several_assignments(self):
        a = self.allower()
        addrs = [f"2001:db8:ffff:ffff:ffff:ffff:ffff:{i:x}" for i in range(1, 4001)]
        a.clock[0] += 1
        a.learned["agent-vm-net.service"] = {x: {"name": "broker.example.com", "seen": a.now()} for x in addrs}
        a.calls.clear()
        a.handle(answer("broker.example.com", "192.0.2.1"))
        args = a.sets()["agent-vm-net.service"]
        self.assertEqual(args[0], "IPAddressAllow=")
        self.assertTrue(all(a.startswith("IPAddressAllow=") and a != "IPAddressAllow=" for a in args[1:]))
        self.assertTrue(all(len(x.encode()) < 32 * 1024 for x in args))
        entries = [e for x in args[1:] for e in x.split("=", 1)[1].split()]
        self.assertEqual(entries, ["127.0.0.53", "198.51.100.7"] + addrs + ["192.0.2.1"])

    def test_a_hung_systemctl_is_a_failed_write(self):
        a = dnsallow.Allower(self.cfg)
        real = dnsallow.subprocess.run

        def hang(*args, **kw):
            self.assertIn("timeout", kw)
            raise subprocess.TimeoutExpired(args[0], kw["timeout"])

        dnsallow.subprocess.run = hang
        try:
            a.handle(answer("broker.example.com", "192.0.2.1"))
            a.startup()
        finally:
            dnsallow.subprocess.run = real
        self.assertEqual(a.learned, {})


if __name__ == "__main__":
    unittest.main()
