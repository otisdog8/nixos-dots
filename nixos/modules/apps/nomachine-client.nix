# NoMachine remote desktop client

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/features/gui.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/audio.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "nomachine-client";
      package = pkgs.nomachine-client;
      packageName = "nxplayer";

      persistence.user.persist = [
        ".nx"
      ];
    };
  }
)
