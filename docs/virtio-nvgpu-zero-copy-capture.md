# Brief for the virtio-nvgpu agents: zero-copy screen capture into a guest

From the nixos-dots side (the VM sandbox tier that consumes virtio-nvgpu at
`display-passthrough` 0869ef9). This asks for one new capability in
virtio-nvgpu and proposes how the work divides. Nothing here needs doing in a
hurry, and every design choice below is open to push-back.

## What we want

A sandboxed application inside a guest (a browser, a video-call client, OBS)
asks for a screen or window share through the ordinary desktop portal, the user
picks what to share in the host's usual picker, and the application receives a
PipeWire video stream whose frames are **host GPU buffers imported into the
guest without a copy**. At 1440p/60 a CPU copy over vsock is ~900 MB/s of
memcpy on both sides, which is why this is worth doing in virtio-nvgpu at all.

## Why it doesn't work today

- The portal's answer is a PipeWire remote **file descriptor**
  (`ScreenCast.OpenPipeWireRemote`), and the frames are further descriptors
  (DMA-BUF planes, or memfds). A VM's session bus reaches the host through a
  byte relay over vsock; descriptors can't cross it.
- virtio-nvgpu is the one piece that can share GPU memory across the boundary,
  but its Wayland proxy carries buffers **guest → host** (a guest client's
  surface), and its allowlist deliberately hides the capture protocols
  (ARCHITECTURE.md §14). The only **host → guest** import is export mode's
  ("a host client's dma-bufs are imported into the channel's render file"),
  which is compositor-VM only and hasn't run on hardware.

## Proposal: a narrow "inject a host buffer" primitive

Keep PipeWire, the portal and every stream protocol **out of the backend**.
The backend is the security-critical process (it holds the host descriptors;
see "Future work: the isolate"), so it should gain as little parsing as
possible. What we need from it is the one thing only it can do: make a host
dma-buf visible to one guest as a guest dma-buf backed by the same memory.

### Host side (backend)

A second socket per backend (flag, e.g. `--inject-socket PATH`, off by
default), accepting peers of **one configured uid only** (ours will be a
per-VM helper user, not the desktop user), speaking a tiny fixed-size message
protocol:

- `IMPORT { plane fds via SCM_RIGHTS, width, height, fourcc, modifier,
  offsets, strides }` → `{ buffer id }`. The backend imports the dma-buf into
  a render file of the VM's own (the export-mode path), checks what it got
  with `DRM_IOCTL_NVIDIA_GEM_IDENTIFY` (review item M-5: refuse anything that
  isn't NVKMS memory, or handle the DMABUF type properly), and keeps the GEM
  reference so the memory can't disappear under a guest mapping.
- `RELEASE { buffer id }`, and everything a peer imported is released when the
  peer disconnects or the VM goes.
- Bounded like everything else: buffers and bytes per peer and per VM (screen
  capture wants ~4–8 buffers per stream, a few streams at most).
- Ideally **read-only** in the guest: the guest has no business writing into
  the compositor's capture buffers. If nvidia-drm can't express that, say so;
  a guest scribbling on its own stream's buffers only hurts itself, but it's
  still worth knowing.

### Guest side (module)

- The guest learns of a buffer by id (we deliver ids and frame metadata over
  our own vsock channel; see below) and turns it into a local dma-buf fd with
  a new ioctl on a node of your choosing, e.g.
  `NVGPU_IOC_INJECTED_OPEN { buffer id } → dma-buf fd`, backed by a GEM proxy
  like any other (§6). Only processes that may open that node can do it
  (we'd give it to one daemon account, as with `/dev/nvgpu-wl`).
- A guest client (no compositor involved) should be able to import that dma-buf into
  Vulkan/EGL on the guest's device with the given modifier, as PipeWire
  consumers do (browsers import into GL/Vulkan; OBS too).

### Sync

PipeWire DMA-BUF streams from xdg-desktop-portal-hyprland carry either
implicit sync or `SPA_META_SyncTimeline` (explicit sync: a DRM syncobj
timeline per buffer, acquire and release points). NVIDIA's implicit sync story
is weak, so we expect to need **syncobjs host → guest** (today they travel
guest → host only, §14): import a host syncobj timeline into the VM once per
stream, then signal/wait points by value. If that's a large piece, a
first cut that has the helper wait for the acquire point on the host before
announcing the frame (a CPU wait, still no copy) is acceptable.

### Questions we can't answer from outside

1. Are xdg-desktop-portal-hyprland's screencast buffers on an NVIDIA host
   nvidia-drm GEM (NVKMS) memory in practice, i.e. importable by the export
   path? (They're allocated through GBM on the render node, so we expect yes;
   the SHM fallback would still need a copy.)
2. Does importing a host dma-buf into a VM's render file and mapping it through
   the shared window need anything the lease/export work hasn't built already?
3. Window budget: capture buffers are placed in the fixed-size window (§17
   "A window that must be sized in advance"). Is 4–8 × 1440p ARGB per stream
   within what you'd provision by default?
4. Would you rather the primitive be a new channel class on `/dev/nvgpu-wl`
   (a "stream" of injected buffers) than a separate socket? We don't mind,
   as long as PipeWire itself stays out of the backend.

## What the nixos-dots side builds (not your concern, for context)

- A per-VM host helper (its own uid) that performs the portal request on the
  VM app's behalf, under the app's flatpak identity so the user sees the usual
  picker, receives the restricted PipeWire remote, consumes the stream, and
  hands each buffer to the backend's inject socket. It sends frame metadata
  (buffer id, damage, crop, cursor, timestamps, sync points) to the guest over
  vsock.
- In the guest: PipeWire, and a small daemon publishing a video source node
  whose buffers are the injected dma-bufs, plus an
  `org.freedesktop.impl.portal.ScreenCast` backend that answers the app with
  that node. Without the primitive the same plumbing falls back to copying
  frames over vsock (SHM), so it's useful either way.

## Not in scope

- Cameras: done in nixos-dots by USB passthrough of the webcam to the VM on
  approval; camera frames are small and mostly MJPEG/YUYV in system memory, so
  zero-copy buys little there.
- Exposing `ext_image_copy_capture` / screencopy through the Wayland proxy.
  It would be zero-copy too (the guest allocates, the compositor blits into
  it), but it bypasses the portal's consent and picker, which is the whole
  point of the portal; not without a host-enforced source restriction.
