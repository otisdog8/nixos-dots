# Prism/Minecraft GPU stall in a virtio-nvgpu VM

Why Prism Launcher / Minecraft in its VM stalled with Xid 69 on the RTX 5090,
and what was changed. The analysis is of virtio-nvgpu revision
`2eec306fae9b0baba495d506c515fb883a649477` (the flake pin at the time), from
the backend's log and the host kernel log of two runs; the fork has moved since
(see *What changed*), so the function names and sizes below describe that
revision, not the current pin.

## Confirmed allocation failure

`device/src/shm.rs` uses a 1 GiB window: UC 32 MiB, WC 768 MiB,
WB 224 MiB. Each zone uses `Share::half(size)` from `device/src/quota.rs`.
Consequently one identified guest process may hold only WC 384 MiB and
WB 112 MiB. The logged `(Owner)` errors are explicitly this test, not the
free-list fragmentation or pool-exhaustion errors.

Run 1: first WC failure at host monotonic 17914.907177; first WB failure
17932.419040; Xid 69 at 17947.789120 (32.882 seconds after first WC failure).
Run 2: first WC failure 18046.861232; first WB failure 18060.653213;
Xid 69 at 18080.547029 (33.686 seconds after first WC failure).

`NvidiaBackend::alloc_zone` falls back from WB to WC on allocation failure,
including per-owner quota failure. Once both quotas are reached this cannot
help. Guest RAM and the graphics mapping window are separate resources.
There is no CLI knob for these RM window sizes: both `shmem_config()` and
backend construction in `device/bin/vhost-user-nvgpu.rs` use the defaults.
The Wayland SHM budget option controls another resource.

## Address translation mismatch

`dispatch_map_memory` indexes `active_maps` by SHM offset and returns that
offset in pLinearAddress. `dispatch_update_device_mapping_info` recognizes
that callers send guest VAs, finds a mapping by client/memory, and translates
addresses for the host. It does NOT record the new guest address.

`dispatch_unmap_memory` subsequently removes ONLY by the supplied
pLinearAddress as an SHM-offset key. The logs contain process VAs such as
0x7d5cb8400000, which cannot be offsets into this 1 GiB window. These calls
miss the index, forward an address of zero to host RM, and retain the entry.

This is a real unsupported address path, but is NOT proof of a permanent
allocation leak. `handle_munmap` decrements active mapping refs but leaves its
extent allocated until RM unmap or descriptor closure. `close_handle` removes
entries by descriptor and `end_rm_mapping` releases them immediately when
refs are zero, or defers them until the remaining VMAs disappear. Therefore
retention from a missed unmap depends on how long the application keeps the
mapping descriptor open. Existing RM unmap tests use the SHM offset, and do
not exercise a guest-VA update followed by unmap.

An address fix should explicitly track guest mapping addresses, scoped by
process/client/object and mapping identity, handle duplicate mappings without
an arbitrary first match, and preserve the live-VMA lifetime protection.
Blindly falling back to the first matching memory object is insufficient.

## Additional failure-path concern

`dispatch_map_memory` calls host RM successfully BEFORE allocating the SHM
extent. If allocation is refused it returns ENOMEM without undoing the host
operation or recording an active mapping. The mapping descriptor's eventual
close can clean this up, but the failure is not transactional. This warrants
a separate failure-injection test; the logs do not establish it causes Xid.

## Validation and what to capture next

A standalone rustc harness imported the actual quota.rs and mmap.rs modules
(with minimal surrounding type stubs). Five tests passed: three existing quota
tests, a test using the exact logged requests showing Owner rejection with
pool capacity remaining, and a mapping-index test showing a guest VA misses
while descriptor cleanup retrieves the retained entry. This is bookkeeping
validation, NOT a host GPU or driver-lifecycle reproduction.

The fork's full `cargo test -p device` was not run, and there was no hardware
reproduction beyond the two logged runs.

To distinguish live demand from accumulated retention, add bounded snapshots
on first quota failure: owner/zone bytes split between active mappings with
refs, active mappings without refs, and deferred live mappings; include map,
unmap, close and refund counters and high-water marks. Existing debug messages
are rate-limited per call site (50 burst, 10/s), so a debug log cannot be used
as a complete accounting ledger.

Recommended order: fix and regression-test guest-address tracking and failed
map rollback; measure retained versus live mappings; then size a configurable
window for actual rendering workloads while retaining per-process isolation.
That revision's sizing comments explicitly derive from enumeration/CUDA/NVENC
traces on a T4, not a game rendering on this RTX 5090. The relationship between
the repeated allocation failures and Xid remains a hypothesis to test.

## What changed

The window and the per-process share are now backend flags in the fork
(`--window-size`, `--window-owner-share`), set per VM from
`sandbox.vm.gpuMemoryMiB` (256-65536 MiB, a multiple of 64, default 1024) and
`sandbox.vm.gpuMemoryProcessPercent` (1-95, default 50), or a group's `vm.*`
for a group VM (`lib/vm/nvgpu.nix` `windowArgs`). nixos-dots patches nothing in
the fork. Prism Launcher, Lunar Client and Steam (and the `games` group)
default to 24576 MiB / 90 %. For another game:

```nix
modules.apps.<game>.sandbox.vm.gpuMemoryMiB = 4096;
```

Guest RAM and VRAM are independent of the window. A change takes a new VM
session.

What a larger share gives up: above 50 %, one guest process can push a zone
down to its reserve, and the VM's other processes share only that. Each VM has
its own backend and window, so this affects availability inside one guest only.
A larger window also lets one guest keep more video memory BAR1-mapped at once,
and BAR1 is shared host-wide. Touched window pages count against the VMM unit's
`MemoryMax` (guest RAM + 512 MiB + the window), so host RAM stays bounded.

This raises capacity. It does not by itself repair the address-translation or
rollback issues above: if those leak, a larger window only delays the stall.
Both were reported to the fork; whether the current pin
fixes them has not been checked here, and the game VMs have not been re-run to
confirm the stall is gone.
