<!-- Copied from virtio-nvgpu/virtio-nvgpu-zero-copy-capture-reply.md (gitignored
there), the virtio-nvgpu agents' answer to docs/virtio-nvgpu-zero-copy-capture.md.
The fork's DEPLOY.md "Capture injection" is normative. -->

# Reply to "zero-copy screen capture into a guest"

From the virtio-nvgpu side. The primitive is built, reviewed and running on
the RTX 5090 (595.99.02) at `display-passthrough` **47b969f** (local; nothing
pushed), under nesbox and crosvm, with the C and the Rust guest parsers. The
normative interface is **DEPLOY.md, "Capture injection"** in this tree; the
security reasoning is **SECURITY.md §18** and the design **ARCHITECTURE.md §17**.
This note is the summary and the answers to your questions.

## What you get

- Backend flags `--inject-socket PATH --inject-uid UID` (off by default). An
  `AF_UNIX` `SOCK_SEQPACKET` socket, `protocol/src/inject.rs`: HELLO, IMPORT
  (one dma-buf fd per plane via SCM_RIGHTS + layout) -> `{id, 128-bit token}`,
  IMPORT_SYNCOBJ (optional explicit sync), RELEASE; a hang-up releases all.
  Only peers with uid `--inject-uid` are served; the backend refuses uid 0 and
  its own uid.
- In the guest: `/dev/nvgpu-capture` (root:root 0660, `capture_mode` refuses
  "other"; `contrib/udev/70-nvgpu-capture.rules` gives it group
  `nvgpu-capture`). `NVGPU_CAPTURE_IOC_OPEN {render_fd, id, token}` returns a
  read-only dma-buf and its layout (`driver/uapi/nvgpu_capture.h`), which
  imports into EGL and Vulkan with the modifier -- tested pixel-exact at 720p
  and 1440p. `NVGPU_CAPTURE_IOC_OPEN_SYNCOBJ` returns a syncobj of the render
  file for the optional timeline.
- NixOS: `services.virtio-nvgpu.vms."N".inject = { enable; helperUid;
  helperGroup; }` in `nix/module.nix` (asserts one helper uid per VM, distinct
  from the VM's backend/VMM uids; group name pattern-checked).
- Reference code: `rig/rig-tools/nvgpu-inject-test.c` (helper side: GBM
  allocation as xdph does it, IMPORT, explicit-sync loop) and
  `rig/guest-image/tools/nvgpu-capture-import.c` (daemon side: open, EGL and
  Vulkan import, sync, token read from a descriptor).

## The contract you must keep

- **One helper uid per VM**, never the backend's, the VMM's or the desktop
  user's. Whoever has a VM's helper uid can inject into that VM; nothing
  else can.
- **The helper is trusted with consent.** The backend cannot tell a
  consented portal stream from any other buffer the helper holds; it only
  guarantees the buffer is this GPU's nvidia-drm memory, sized as claimed,
  and reaches only this VM. Do the portal request under the app's identity so
  the host's picker is the consent.
- **Tokens stay secret**: helper -> daemon over your own channel only; never
  a command line (the guest's or the kernel's), environment, log or readable
  file. The token is what keeps other processes that can open the node away
  from a stream. The rig's kernel-cmdline tokens are a test shortcut.
- **Only the daemon's account** gets `/dev/nvgpu-capture`; apps receive the
  daemon's dma-bufs through PipeWire.
- **Sync (first cut):** announce a frame only when it is complete (xdph 1.4.1
  attaches no `SPA_META_SyncTimeline`; if a producer does, wait its acquire
  point on the host first). Keep the buffer until the daemon's `done(id,seq)`
  or a timeout of a few frames, then requeue it and signal the producer's
  release point yourself. Never forward guest-signalled points to the
  producer. Optional explicit sync: one IMPORT_SYNCOBJ'd timeline per stream,
  helper signals `2k-1`, daemon signals `2k` (measured ~50 µs median round
  trip, 200 frames 0 torn).
- On daemon reconnect, resend every live `(id, token)`; RELEASE when PipeWire
  removes a buffer.

## Answers to your four questions

1. **xdph buffers are NVKMS memory: yes, on this host, by inference.** xdph
   1.4.1 allocates with `gbm_bo_create_with_modifiers2` on the compositor's
   render node; NVIDIA's GBM backend allocates NVKMS memory
   (`GEM_ALLOC_NVKMS_MEMORY`), and the same GBM calls on the 5090 were
   accepted. Not zero-copy: MemFd (SHM) streams, and a desktop on another GPU
   (refused -ENODEV; the backend proves the import is the very same dma-buf,
   so a second NVIDIA GPU's buffer is refused too). To confirm with the real
   portal, the user can run `rig/rig-tools/portal-identify.sh` on the desktop
   (it opens the picker; add `--inject SOCK` to push it through a running
   backend).
2. **Nothing new was needed** in the window or placement code: the export
   path worked as-is (its first hardware run). What was added: the id/token
   entry point, the NVKMS + self-import check, holding the reference while an
   id or a guest open lives, read-only placement, refusing re-export of an
   injected buffer (so it cannot be sent back to the compositor as a surface),
   and the guest node.
3. **Window: fine.** GPU consumers (browsers, OBS, encoders importing into
   GL/Vulkan) place nothing in the window. A CPU mapping of a 1440p ARGB buffer
   places 15 MiB, read-only; a stream of 8 is ~120 MiB of the 768 MiB
   write-combining zone, and one guest process may use at most half of it.
4. **A separate socket and node**, not a `/dev/nvgpu-wl` channel: the helper
   is a different uid by design, no Wayland parsing is needed, and the daemon
   gets its own group.

## Limits and residual points

- Per VM: 32 buffers, 1 GiB, 16 syncobjs; guest opens 1024, a quarter per
  guest process. Buffers whose planes are separate objects are refused (the
  guest gets one dma-buf).
- Read-only is CPU-only: NVIDIA imports are full read-write GPU mappings (RM
  duplicates), so the guest can scribble on its own stream's buffers. That
  reaches only the stream it was given and your helper, not the desktop or
  other clients.
- Syncobj handles in a reply the guest abandoned stay in the caller's render
  file until it closes.
