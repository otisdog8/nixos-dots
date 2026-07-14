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
{ lib }:
caps:
{
  config,
  lib,
  pkgs,
  sloth,
  ...
}:
let
  # Extra binds declared as capabilities: absolute → as-is, "." / "./x" → under
  # $PWD, otherwise home-relative. (Matches the extraBinds resolution in
  # nixpak-pkg.nix; the dedicated sharedHome nuance stays on extraBinds for now.)
  resolveBind =
    p:
    if lib.hasPrefix "/" p then
      p
    else if lib.hasPrefix "." p then
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
    bubblewrap.bind.dev = [
      "/dev/dri"
      "/dev/nvidia0"
      "/dev/nvidiactl"
      "/dev/nvidia-modeset"
      "/dev/nvidia-uvm"
      "/dev/nvidia-uvm-tools"
    ];
    bubblewrap.bind.rw = [
      "/sys/dev/char"
      "/sys/devices"
      "/sys/class/drm"
    ];
    bubblewrap.bind.ro = [
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

  (lib.mkIf caps.audio {
    bubblewrap.sockets = {
      pulse = true;
      pipewire = true;
    };
  })

  (lib.mkIf caps.wayland {
    bubblewrap.sockets.wayland = true;
  })

  (lib.mkIf caps.x11 {
    bubblewrap.bind.ro = [ "/tmp/.X11-unix" ];
  })

  # FIDO/WebAuthn hardware keys — raw HID. Deliberately NOT part of `gui`: only
  # apps that actually use security keys (browsers) should reach /dev/hidraw*.
  (lib.mkIf caps.fido {
    bubblewrap.bind.dev = [
      "/dev/hidraw0"
      "/dev/hidraw1"
      "/dev/hidraw2"
      "/dev/hidraw3"
      "/dev/hidraw4"
      "/dev/hidraw5"
      "/dev/hidraw6"
      "/dev/hidraw7"
      "/dev/hidraw8"
      "/dev/hidraw9"
    ];
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
