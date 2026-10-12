# Web browser feature
{ config, lib, ... }:
let
  # The browser's own org.freedesktop.Application / gecko-remote name prefix
  # (app.dbusName, e.g. "org.mozilla.zen"). gecko registers
  # <dbusName>.<profile-instance> (MOZ_DBUS_REMOTE, open-links.nix); the "<name>.*"
  # policy covers that subtree and the bare name.
  ownName = config.app.dbusName;
in
{
  # Browsers are GUI apps with network + FIDO/WebAuthn security keys + audio
  # (web audio/video), and may ask the portal for
  # screen sharing (WebRTC getDisplayMedia) — the host picker still gates it.
  imports = [
    ./gui.nix
    ./network.nix
    ./fido.nix
    ./microphone.nix # audio out, and the mic when you allow it (WebRTC calls)
    ./screen-capture.nix
  ];

  config.app = {
    # WebRTC cameras via the portal (PipeWire camera); no raw /dev/video* nodes.
    portalInterfaces = [ "Camera" ];

    # Browser-specific nixpak configuration
    nixpakModules = [
      (
        {
          config,
          lib,
          pkgs,
          sloth,
          ...
        }:
        {
          # Browsers need access to downloads
          bubblewrap.bind.rw = [
            (sloth.concat' sloth.homeDir "/Downloads")
            (sloth.concat' sloth.homeDir "/Documents/tthtml")
          ];

          # D-Bus names the browser may OWN. SECURITY: only its OWN remote-control
          # name, never another browser's. The launcher forwards URLs (OAuth /
          # magic-login links included) to whoever owns <dbusName>.*, so a blanket
          # own-list would let any compromised browser register e.g.
          # org.mozilla.zen.0 and receive every link meant for zen. Other browsers'
          # names stay talk-only (open-links.nix).
          dbus.policies =
            lib.optionalAttrs (ownName != "") {
              "${ownName}.*" = "own";
            }
            // {
              # MPRIS media player controls (for playerctl, media keys, etc.)
              "org.mpris.MediaPlayer2.*" = "own";
            };
        }
      )
    ];
  };
}
