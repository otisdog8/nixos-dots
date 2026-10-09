# Layer-2 lowering: app.capabilities (backend-agnostic Layer-1 vocabulary)
# → a single nixpak/bwrap module. This is where a high-level grant like
# `capabilities.gpu = true` becomes the concrete device/sys binds.
#
# The VM backend will get its OWN lowering of the same capabilities (virtio-fs,
# waypipe, vsock proxies); that is the whole point of expressing grants as
# capabilities rather than raw nixpakModules — one app definition, many backends.
#
# Priority note: bubblewrap.network is set `mkOverride 999 false` in
# nixpak-pkg.nix (an "off unless asked" default). A plain `true` here is priority
# 100 (higher than 999), so `mkIf caps.network { ... network = true }` wins — same
# mechanism the old network.nix feature relied on.
{
  lib,
  # Device nodes the `gpu` capability binds. Default: every GPU on the host.
  # Multi-GPU hosts where only one card drives the display should narrow this
  # via modules.sandbox.gpuDevices (threaded through both backends): chromium's
  # Wayland path opens the FIRST openable /dev/dri/renderD* and NVIDIA's Vulkan
  # ICD enumerates every /dev/nvidia*, so a visible compute-only card gets
  # picked for buffer allocation while the compositor/window lives on the
  # display card — cross-GPU dmabuf import then fails on every frame
  # (EGL_BAD_ALLOC / VK_ERROR_OUT_OF_DEVICE_MEMORY → context-lost loop).
  gpuDevices ? [
    "/dev/dri"
    "/dev/nvidia0"
    "/dev/nvidia1"
    "/dev/nvidiactl"
    "/dev/nvidia-modeset"
    "/dev/nvidia-uvm"
    "/dev/nvidia-uvm-tools"
  ],
}:
caps:
{
  config,
  lib,
  pkgs,
  sloth,
  ...
}:
let
  bindPath = import ./paths.nix { inherit lib; };
  # Same resolution as extraBinds (lib/paths.nix), minus the dedicated sharedHome
  # remap.
  resolveBind =
    p:
    if bindPath.isAbsolute p then
      p
    else if bindPath.isPwdRelative p then
      sloth.concat' (sloth.env "PWD") "/${p}"
    else
      sloth.concat' sloth.homeDir "/${p}";
in
lib.mkMerge [
  (lib.mkIf caps.network {
    bubblewrap.network = true;
    etc.sslCertificates.enable = true;
  })

  (lib.mkIf caps.gpu {
    bubblewrap.bind.dev = gpuDevices;
    bubblewrap.bind.rw = [
      "/sys/dev/char"
      "/sys/devices"
      "/sys/class/drm"
    ];
    bubblewrap.bind.ro = [
      # NVIDIA userspace resolves GPUs through /sys/bus/pci/devices symlinks and
      # reads /sys/module/nvidia_drm/parameters/modeset to detect GBM/dmabuf
      # support. Without these, dmabuf import into EGL/Vulkan fails on every
      # frame (eglCreateImage EGL_BAD_ALLOC / VK_ERROR_OUT_OF_DEVICE_MEMORY →
      # context-lost loop). Flatpak binds all of /sys/bus + /sys/class; we add
      # the two specific subtrees to avoid overlapping the /sys/class/drm rw
      # bind above.
      "/sys/bus/pci"
      "/sys/module"
      "/run/opengl-driver"
      "/run/opengl-driver-32"
      "/etc/static/egl"
      "/etc/egl"
      "/etc/vulkan"
      "/etc/OpenCL"
      "/run/current-system/sw/share/glvnd"
      "/run/current-system/sw/share/vulkan"
    ];
  })

  # Audio: PulseAudio only, at $XDG_RUNTIME_DIR/pulse/native — the sandbox
  # broker's filtered socket (playback; recording only with the microphone
  # capability and your approval), which the backends put there. Never
  # PipeWire's own socket: that is the whole media graph (every microphone,
  # every app's sound, screen casts) with nothing in between. No shared memory:
  # descriptors don't cross the filter.
  (lib.mkIf caps.audio {
    bubblewrap.sockets.pulse = true;
    bubblewrap.env.PULSE_CLIENTCONFIG = "${pkgs.writeText "sandbox-pulse-client.conf" ''
      enable-shm = no
      enable-memfd = no
      autospawn = no
    ''}";
  })

  (lib.mkIf caps.wayland {
    bubblewrap.sockets.wayland = true;
  })

  (lib.mkIf caps.x11 {
    bubblewrap.bind.ro = [ "/tmp/.X11-unix" ];
  })

  # Every sandbox gets a private /tmp. bwrap's root is an empty tmpfs, so without
  # it /tmp doesn't exist: here-docs, mktemp, Node's os.tmpdir() and Chromium's
  # ProcessSingleton ("Failed to create socket directory", exit 21) all fail.
  # Binds under /tmp (X11 socket, a $PWD there) sit on top of it: our patched
  # nixpak mounts tmpfs before binds (nixpak-pkg.nix).
  {
    bubblewrap.tmpfs = [ "/tmp" ];
    bubblewrap.env.TMPDIR = "/tmp";
  }

  # FIDO/WebAuthn hardware keys — raw HID. Deliberately NOT part of `gui`: only
  # apps that actually use security keys (browsers) should reach /dev/hidraw*.
  # Nodes are bound individually (bind-try skips absent ones), so only keys
  # plugged in when the app starts are visible; a later key needs a restart.
  # Dedicated uids can open them via the `fido` group (modules/system/sandbox.nix).
  # TODO: better handling of FIDO keys. Known gaps: a key plugged in after
  # the app starts isn't seen, and a fixed range of hidraw nodes is bound
  # rather than the keys themselves. VMs get keys through the broker (hotplug,
  # prompted); containers could too.
  (lib.mkIf caps.fido {
    bubblewrap.bind.dev = map (n: "/dev/hidraw${toString n}") (lib.range 0 31);
    # libudev needs these to enumerate and identify FIDO devices.
    bubblewrap.bind.ro = [
      "/run/udev"
      "/sys/class/hidraw"
      "/sys/bus/hid"
    ];
  })

  # $PWD rw — for CLI tools/agents working in the current project directory.
  (lib.mkIf caps.cwd {
    bubblewrap.bind.rw = [ (sloth.env "PWD") ];
  })

  # Read-only host git config so sandboxed tools inherit identity/signing.
  (lib.mkIf caps.gitConfig {
    bubblewrap.bind.ro = [
      (sloth.concat' sloth.homeDir "/.gitconfig")
      (sloth.concat' sloth.homeDir "/.config/git")
    ];
  })

  # Declarative extra binds (structured alternative to raw nixpakModules).
  { bubblewrap.bind.rw = map resolveBind caps.binds.rw; }
  { bubblewrap.bind.ro = map resolveBind caps.binds.ro; }
  { bubblewrap.bind.dev = caps.binds.dev; }

  { dbus.policies = caps.dbus.policies; }
]
