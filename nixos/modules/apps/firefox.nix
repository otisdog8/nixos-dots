# Firefox web browser (tmpfs-only, all data cleared on reboot)

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
    imports = [
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/tmpfs-homedir.nix
    ];

    config.app = {
      name = "firefox";
      package = pkgs.firefox;
      packageName = "firefox";
    };
  }
)
