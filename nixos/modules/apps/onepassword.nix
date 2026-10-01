# 1Password GUI — dedicated-uid sandbox. The crown-jewel goal: the local vault
# (~/.config/1Password) runs as app-onepassword, DAC-hidden from a compromised jrt.
#
# Scope (per the deliberate decision): GUI + vault only. NO browser integration and
# NO SSH agent — the two hard cross-uid channels — so this is "just another dedicated
# Electron app" with an extra-sensitive stash. Consequences:
#   - In its container, unlock is by the 1Password ACCOUNT password: the app refuses
#     polkit inside nixpak's user namespace (root-owned files show as uid 65534,
#     and it checks the system bus directory is root's), so there is no
#     system-auth unlock and no CLI integration (docs/op-broker.md).
#   - In its VM (sandbox.mode = "vm"), onepassword-system-auth.nix gives it
#     "unlock using system authentication" and CLI authorization (op-broker),
#     answered by you authenticating on the HOST with your polkit agent.
#   - Its container gets no Secret Service (org.freedesktop.secrets): the vault key
#     material stays in its OWN app-onepassword profile, never in jrt's kwallet.
#   - Its VM does (sandbox.vm.hostKeyring, on below), for one thing: the token that
#     remembers this device for two-factor sign-in. Without a keyring 1Password
#     asks for the 2FA code at every start. The VM can then read whatever
#     kwallet serves unlocked; the vault itself is still unlocked only by the
#     account password or system authentication, not by anything kept there.

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
      # No needs-gpu.nix: the vault's app renders in software. Its container
      # gets no GPU device nodes, and its VM gets crosvm's cross-domain display
      # instead of virtio-nvgpu — no host GPU driver interface reachable from
      # the sandbox holding the vault.
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
          # In its VM by default: only there can the app authorize op-broker's
          # `op` and offer system authentication (docs/op-broker.md, "Why not
          # the container"); the container stays available per host.
          modules.apps.onepassword.sandbox.mode = lib.mkDefault "vm";
          modules.apps.onepassword.sandbox.vm.hostKeyring = lib.mkDefault true;
          users.users."app-onepassword".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
