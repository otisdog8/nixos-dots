# 1Password GUI — dedicated-uid sandbox. The crown-jewel goal: the local vault
# (~/.config/1Password) runs as app-onepassword, DAC-hidden from a compromised jrt.
#
# Scope (per the deliberate decision): GUI + vault only. NO browser integration and
# NO SSH agent — the two hard cross-uid channels — so this is "just another dedicated
# Electron app" with an extra-sensitive stash. Consequences:
#   - Unlock is by the 1Password ACCOUNT password (system-auth/polkit unlock is gone
#     with programs._1password-gui; see auth.nix). Arguably better — no system-auth tie.
#   - We do NOT grant the Secret Service (org.freedesktop.secrets) DBus policy, so the
#     app can't stash its local key in jrt's kwallet — which would defeat the hiding.
#     It keeps the vault key material inside its OWN app-onepassword profile instead.

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      # chromium.nix (Electron): carves .config/1Password's regenerable caches to
      # /cache, keeps the profile+vault on persist. Also pulls in gui.nix.
      ../../../lib/features/chromium.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/xdg-desktop.nix
      # 1Password lives in the tray.
      ../../../lib/features/system-tray.nix
    ];

    config.app = {
      name = "onepassword";
      # Force native Wayland (dedicated uid can't auth to XWayland; the hint alone
      # falls back to X11), same as vesktop/brave.
      package = pkgs.symlinkJoin {
        name = "1password-wayland";
        paths = [ pkgs._1password-gui ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          rm $out/bin/1password
          makeWrapper ${pkgs._1password-gui}/bin/1password $out/bin/1password \
            --add-flags "--ozone-platform=wayland"
        '';
      };
      packageName = "1password";
      desktopFileName = "1password.desktop";

      # The Electron profile + local vault. chromium.nix supplies the .config/1Password
      # storage (persist profile + carved /cache caches) from basePath.
      chromium.basePath = ".config/1Password";

      defaultBackend = "systemd";
      storage = [
        # Non-cache 1Password state that lives outside the Electron profile.
        {
          path = ".1password";
          tier = "persist";
        }
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.onepassword.sandbox.dedicatedUser = true;
          users.users."app-onepassword".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
