# PCR 15 Verification Runbook

What this module does, why, and how to enable it on a new host.

## Threat model recap

Pre-boot TPM2 PCR binding (PCRs 0, 2, 7) protects against firmware /
secure-boot tampering, but doesn't bind to *which disk was unlocked*. An
attacker with brief physical access can swap the LUKS partition for a fake
one (same UUID, attacker-chosen password), let TPM unseal fall back to
password (theirs), and boot a malicious init under the unchanged pre-boot
PCR state. From inside that malicious OS the TPM still happily unseals the
real volume key, since none of the bound PCRs changed.

See oddlama, "Bypassing disk encryption on systems with automatic TPM2
unlock" (2025-01-16) for the full writeup and PoC.

This module measures each LUKS volume key into PCR 15 after unlock and
asserts the value matches a recorded known-good hash before the boot is
allowed to proceed to `sysroot.mount`. A swapped disk → different volume
key → different PCR 15 → boot aborts.

## When to enable

Hosts that (a) use TPM2 to auto-unlock LUKS and (b) have a plausible "brief
physical access" threat — laptops, kiosks, anything that leaves your sight.
Servers in a locked rack with their own physical-security story can skip
this.

Hosts where LUKS is unlocked by password every boot don't need it — no TPM
to abuse.

## Prerequisites

- `boot.initrd.systemd.enable = true` (provided globally by
  `modules/system/secureboot.nix`).
- `boot.initrd.systemd.tpm2.enable = true` (same).
- TPM2 already enrolled into the LUKS header via `systemd-cryptenroll`.
  Verify with `sudo cryptsetup luksDump <luks-device> | grep -i token`.
- A root account with a real `hashedPassword` set (so the initrd emergency
  shell has something to authenticate against). The module wires
  `boot.initrd.systemd.emergencyAccess` to
  `config.users.users.root.hashedPassword` automatically.

## Critical: crypttab options come as a pair

The module sets *both* `tpm2-device=auto` and `tpm2-measure-pcr=yes` on the
LUKS device. The pairing is not cosmetic — setting `tpm2-measure-pcr=yes`
alone breaks TPM unlock entirely.

Reason (see systemd issue #37072): the presence of `tpm2-measure-pcr=` in
the crypttab options flips `systemd-cryptsetup` from its libcryptsetup
plugin path (which auto-detects the LUKS TPM2 token) to a "respect crypttab
options literally" path. In that mode, TPM2 unseal is only attempted if
`tpm2-device=` is also declared. Without it, the service silently falls
back to passphrase prompt — symptom looks exactly like the TPM enrollment
is broken when it isn't. If you ever rework this module to make the
crypttab options conditional, keep them tied together.

## Enrollment procedure

Two-rebuild dance because the expected PCR 15 value is something the system
can only learn from itself after a clean boot.

### 1. Measurement-only boot

In the host's `default.nix`, add:

```nix
modules.system.pcr-verification = {
  enable = true;
  # expectedPcr15 = null;   # leave commented or null
};
```

`sudo nixos-rebuild switch --flake .#<hostname>` and reboot. TPM auto-unlock
should behave exactly as before — measurement happens after unseal, so it
can't interfere with key release. The verification service is gated off
(`expectedPcr15 = null`), so nothing asserts yet.

### 2. Capture the expected PCR 15 value

After the system is up:

```
sudo systemd-analyze pcrs 15 --json=short
```

Copy the `sha256` field.

### 3. Enforcement boot

Set the captured value in the host config:

```nix
modules.system.pcr-verification = {
  enable = true;
  expectedPcr15 = "<paste sha256 here>";
};
```

Rebuild and reboot. After login, confirm the service ran:

```
journalctl -b -u check-pcr15.service
```

Should show `PCR 15 verification OK (<hash>)`.

## What changes PCR 15 (and what doesn't)

PCR 15 is extended with hashes derived from:

- Each unlocked LUKS volume's volume key + volume name + activation source
  (via `tpm2-measure-pcr=yes` in crypttab).
- Anything else upstream systemd measures into PCR 15 (machine-id via
  `systemd-pcrmachine.service`, root/var fs identity via
  `systemd-pcrfs@.service`).

**Stable across:**

- Kernel updates, NixOS generations, NixOS rebuilds.
- Firmware updates (those move PCRs 0/2, not 15).
- Adding/removing TPM2 token slots (`systemd-cryptenroll` doesn't change
  the volume key).

**Will require re-capture:**

- `luksFormat` on the device (new volume key).
- Changing the LUKS device name in Nix (currently `"luks"` everywhere).
- Changing `/etc/machine-id` (it's persisted in `/persist`, don't).
- Changing root/var filesystem UUIDs.

If you ever see `PCR 15 verification FAILED` on a known-clean boot: re-run
the capture step, paste the new value, rebuild.

## Recovery

If verification fails the system drops to the initrd emergency shell.
Authenticate with the root password (the same hash already set in
`users.users.root.hashedPassword`).

From the rescue shell, options:

- Read the logged actual vs expected: `journalctl -b -u check-pcr15`.
- If the mismatch is benign (you just changed something tracked by PCR 15),
  set `cfg.expectedPcr15 = null` in the next rebuild, capture, and re-enable.
- If unexpected, treat as potential tampering: power off, investigate from a
  known-good live image.

## Coverage notes

- This protects the LUKS path *only*. Native-encrypted filesystems (ZFS,
  bcachefs) unlocked via clevis bypass `systemd-cryptsetup` and therefore the
  `tpm2-measure-pcr=yes` hook. On `recusant`, the LUKS root is covered; the
  bcachefs data drive is not.
- This is post-unlock verification. For belt-and-suspenders, also tighten
  the TPM unseal binding to `0+2+7+12+13+15:sha256=0` (see "Future
  hardening" below). PCR 15 = 0 prevents a malicious init from being able
  to pull the key out of the TPM at all (since PCR 15 is non-zero by the
  time userspace runs). PCRs 12 and 13 cover microcode / credentials /
  sysext tampering at boot. Each host needs its own `systemd-cryptenroll`
  invocation.

## Future hardening: tighter TPM unseal binding

Re-enroll the TPM2 LUKS slot so unsealing requires the full pre-boot trust
chain to match *and* PCR 15 to still be all-zeros (i.e., the boot-time
pre-measurement state):

```
sudo systemd-cryptenroll \
  --wipe-slot=tpm2 \
  --tpm2-device=auto \
  --tpm2-pcrs=0+2+7+12+13 \
  --tpm2-pcrs=15:sha256=0000000000000000000000000000000000000000000000000000000000000000 \
  /dev/disk/by-uuid/<your-luks-uuid>
```

PCR selection rationale (UAPI Linux TPM PCR Registry):

- **0** platform-code (firmware) — changes on firmware updates only.
- **2** external-code — option ROMs on pluggable hardware. Stable.
- **7** secure-boot-policy — Secure Boot state + keys (PK/KEK/db/dbx).
- **12** kernel-config — on Lanzaboote (UKI, no menu cmdline override) this
  captures microcode addons / credentials / sysext addons. Empirically
  stable across `nixos-rebuild` (the embedded cmdline is measured into PCR
  11 via the UKI hash, not 12, so it doesn't churn this register).
- **13** sysexts — zero on this setup (no sysexts in use). Binding to
  current value asserts "no sysext was slipped in."
- **15** explicit zero — see paragraph above.

Skipped on purpose:

- **PCR 1** — host platform config; shifts on RAM/CPU swaps without any
  actual compromise.
- **PCR 4** — boot-loader-code; redundant with PCR 7.
- **PCR 11** — captures the UKI hash, rotates every `nixos-rebuild`.
  Useful only with signed PCR policies (`ukify --pcr-public-key …` +
  `systemd-cryptenroll --tpm2-public-key …`), which lanzaboote doesn't
  expose turnkey.

**Re-enroll triggers** (PCR-12/13 capture is current-value, so redo if any
of these change):

- Microcode bump (`pkgs.amd-ucode` / `pkgs.microcodeIntel` revision changes
  propagating into the UKI's `.ucode` section).
- Adding systemd credentials, sysext addons, devicetree overlays to the
  boot path.
- Manually overriding the kernel cmdline from systemd-boot's menu (the
  editor is disabled by default in this repo's setup anyway).

If unseal fails after one of these, the LUKS passphrase still works as
fallback; recapture and re-enroll, no data lost.

Keep a LUKS passphrase backup before running this — `--wipe-slot=tpm2`
deletes the existing TPM-bound keyslot, so a botched re-enrollment with no
passphrase backup would lock you out.
