# Brief for virtio-nvgpu: what nixos-dots patches, and what to upstream

From the nixos-dots side (branch `vm-sandbox`), 2026-09-29, against the pinned
fork revision `2eec306` (`display-passthrough`). nixos-dots builds the fork in
`lib/vm/nvgpu.nix` and changes it in three places. Each is a stopgap until the
fork does it itself; once it does, nixos-dots drops its copy and passes a flag.

## 1. Window size and per-process share (backend)

**What nixos-dots does.** `lib/vm/nvgpu.nix` `backendFor { windowMiB; ownerPercent; }`
builds a second backend when a VM asks for anything but 1024 MiB / 50 %
(`modules.apps.<app>.sandbox.vm.gpuMemoryMiB` / `gpuMemoryProcessPercent`, or a
group's `vm.*`). Steam, Prism Launcher and Lunar Client ask for 16384 MiB / 90 %.
The variant:

- appends `ZoneConfig::configured_window()` to `device/src/shm.rs`:
  `default_1gib()`'s split times `windowMiB / 1024` (at 16 GiB: UC 512, WC
  12288, WB 3584 MiB), asserting `default_1gib()` is still 1 GiB;
- appends `ShmAllocator::set_owner_percent(p)`: for each zone,
  `per_owner = size * p / 100` (page-aligned down),
  `reserve = min(size / 8, size - per_owner)`, `floor = min(size / 16, reserve)`.
  At p = 50 this is exactly `Share::half`. The reserve shrinks above 87.5 %,
  otherwise the reserve would cap the share below what was asked for;
- appends `NvidiaBackend::with_configured_window()` (both of the above) to
  `device/src/nvidia.rs`;
- in `device/bin/vhost-user-nvgpu.rs`, replaces `shmem_config()`'s
  `ZoneConfig::default_1gib().total()` and `run()`'s
  `NvidiaBackend::with_default_zones()` with the configured ones
  (`--replace-fail`: a fork that moves either line breaks the build), and the
  GET_SHMEM_CONFIG test's `1 << 30` with the configured size;
- runs its own tests and `shmem_config_names_the_window_and_the_aperture_only_with_compute`
  in the build (`cargo test -p device --lib --bin vhost-user-nvgpu -- nixos_dots shmem_config`).

**Why.** Prism/Minecraft on the RTX 5090 (595.99.02). The backend logged ~950
`NV_ESC_RM_MAP_MEMORY: SHM alloc failed ... WriteCombine zone: guest process ...
holds 0x17f82000 of 0x30000000 bytes and may not take 0x200000 more (Owner)`:
one process at its 384 MiB half of the 768 MiB WC zone, with the zone not full.
WB failures followed. Both runs ended in `Xid 69` (Class Error, class `ce97`)
about 33 s after the first WC refusal (nixos-dots `prism-vm-host.log`,
`prism-host-kernel.log`, `docs/INVESTIGATION-prism-gpu-stall.md`). As
`ZoneConfig::default_1gib`'s own comment says, the split came from
enumeration, CUDA and NVENC on a T4, not from a game rendering.

**What to upstream (recommended shape).**

- `--window-size <MiB>` (default 1024) and `--window-owner-share <percent>`
  (default 50) on `vhost-user-nvgpu`. Both go into the one `ZoneConfig` that
  sizes the allocator and answers GET_SHMEM_CONFIG, so the two cannot drift.
  Validate them: page-multiple zones; window plus UVM aperture within crosvm's
  `MAX_SHARED_MEMORY_REGION_SIZE` (64 GiB, patch 0006); share 1-95 %.
- Decide how a zone scales: proportionally (what nixos-dots does) or with WC
  taking most of the growth (game traces are WC-heavy).
- Record the share in `quota.rs` as a `Share::percent(size, p)` next to
  `Share::half`. Say in SECURITY.md what it gives up: at p > 50,
  `owners_to_exhaust` is 1, so one process can push the zone to its reserve.
  Other processes keep only the reserve (at 16 GiB / 90 %: about 1.2 GiB of WC,
  each at most the 768 MiB floor). That is still more than the default's
  whole-share 384 MiB. This is availability inside one guest only. Each VM has
  its own backend and window.
- DEPLOY.md: "the shared window adds up to 1 GiB (sparse)" becomes the
  configured size. Note that the backend's `MemoryMax=2G` is unaffected. Pages
  of the memfd a guest touches are charged to whoever faults them: the VMM, as
  the guest's.
- Note the host GPU effect. More window lets one guest keep more video memory
  CPU-mapped (BAR1) at once: up to about 11 GiB at 16 GiB / 90 %. BAR1 is
  shared host-wide with the desktop and other VMs. Allocation (VRAM itself) was
  never bounded by the window.

**The window is probably not the root cause.** Two defects in the fork
(details in nixos-dots `docs/INVESTIGATION-prism-gpu-stall.md`) may turn a
larger window into a slower failure:

1. `dispatch_unmap_memory` looks mappings up by the SHM offset it wrote into
   `pLinearAddress`. Clients that went through `UPDATE_DEVICE_MAPPING_INFO`
   unmap by their *guest VA*. The log has 11 `UNMAP_MEMORY: no mapping for
   pLinearAddress=0x7d5cb8400000`-style misses. The extent then stays charged
   until the memory descriptor closes. Track the guest VA per mapping, or look
   up by (client, memory, VA).
2. `dispatch_map_memory` calls RM before it allocates the extent. A refused
   allocation returns ENOMEM with the host mapping still made and unrecorded.
   Make it transactional.

A regression test for (1): map, UPDATE_DEVICE_MAPPING_INFO, unmap by VA, and
check the zone is back to where it was.

## 2. Guest module: legacy SYNCOBJ_HANDLE ioctls

**Patch.** `lib/vm/patches/nvgpu-syncobj-legacy-handle.patch` (on `driver/nvgpu_fence.c`).
`SYNCOBJ_HANDLE_TO_FD` / `FD_TO_HANDLE` encoded with the 16-byte
`struct drm_syncobj_handle` (headers from before the timeline `point` field,
e.g. the Steam runtime's libdrm) got EINVAL from `nvgpu_fence_copy_in`'s exact
`cmd` match. The DRM core accepts them: it zero-extends the input and copies out
the caller's size. The patch adds `nvgpu_fence_copy_handle()`, which accepts
exactly the native size or 16, copies `_IOC_SIZE(cmd)` in after zeroing, forwards
the **native** command to the host, and copies `_IOC_SIZE(cmd)` back out.

**Upstream.** Take it as is, or generalise: a copy-in helper for any core DRM
ioctl whose struct grew, bounded to the sizes that exist. Add a rig case with a
16-byte caller.

## 3. Guest module: compat ioctl on /dev/nvidiactl and /dev/nvidiaN

**Patch.** `lib/vm/patches/nvgpu-rm-compat-ioctl.patch` (on `driver/nvgpu_main.c`):
`.compat_ioctl = compat_ptr_ioctl` on `nvgpu_gpu_fops` and `nvgpu_ctl_fops`. Without
it, every ioctl from a 32-bit process (Steam's client, 32-bit games' GL/Vulkan
driver) on those nodes was ENOTTY. Only the DRM node had a compat path.

**Why it is sound.** `nvidia.ko` does the same: its compat handler is its
native one, because RM's parameter structs are fixed-width with `NvP64`
pointers. The DRM node's own compat path already sends type-`'F'` (RM) ioctls
the native way with the pointer widened. A compat caller can supply no input a
native caller cannot, so this adds no new input space to `nvgpu_ioctl_fd`. The
only differences are `in_compat_syscall()` (read only by the KMS path in
`nvgpu_i2.c`) and a 32-bit address space. `/dev/nvidia-uvm` stays native-only,
which is fine: 32-bit CUDA is gone.

**Upstream.** Take it. Add rig coverage with a 32-bit client (i686 `nvidia-smi`
or a 32-bit Vulkan `vulkaninfo`). Audit `nvgpu_osdesc` and the RM
embedded-pointer tables for any assumption that a user VA is above 4 GiB.

## 4. Deployment facts the fork's docs are missing

Found while wiring the units in nixos-dots (`lib/vm/instance.nix`):

- **The VMM of a compute VM** (patched crosvm, patch 0007 `RegisterUvmPool`)
  needs the `mincore` syscall. It is not in systemd's `@system-service`. The
  VMM also needs the device cgroup to allow *write* to `/dev/nvidia-uvm`:
  `mincore_reports_on()` calls `access("/proc/self/fd/N", W_OK)`, and
  `can_do_mincore` itself asks `file_permission(MAY_WRITE)`, both of which run
  `devcgroup_inode_permission`. Under `DevicePolicy=closed` without it, every
  pool is refused (EACCES). nixos-dots grants `/dev/nvidia-uvm w` (not `rw`) and
  hides the path with `InaccessiblePaths=`, because the check goes through the
  descriptor. It adds no group, because the node is 0666 on NixOS. Worth a line
  in DEPLOY.md's VMM section.
- **The open driver registers major 195 as `nvidia`** in `/proc/devices`, not
  `nvidia-frontend`. A unit with `DeviceAllow=char-nvidia-frontend` alone denies
  `/dev/nvidia0`. The contrib unit sets no device policy, so it is unaffected,
  but anyone who adds one will hit this.

## When the fork has these

nixos-dots then drops `backendFor`'s source edits (it keeps the options and
passes `--window-size` / `--window-owner-share`), deletes the two
`lib/vm/patches/nvgpu-*.patch`, and bumps the pin. Until then, every fork
bump must build `backendFor { windowMiB = 16384; ownerPercent = 90; }` and the
kmod. Both fail loudly when an anchor moves.
