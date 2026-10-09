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
      # In its container: force native Wayland (dedicated uid can't auth to
      # XWayland; the hint alone falls back to X11), same as vesktop/brave.
      # In its VM, with the guest's own X server (sandbox.vm.x11 below): X11.
      # 1Password sets the clipboard itself, and on native Wayland through
      # data-control, which a sandbox's Wayland socket doesn't have (and the
      # guest's display proxy doesn't carry): nothing it copied reached the
      # clipboard. As an X11 client its selection goes through Xwayland to the
      # VM's ordinary Wayland clipboard. /run/sbx/display.env is the guest's
      # (lib/vm/guest.nix); DISPLAY is set there only with vm.x11.
      package = pkgs.symlinkJoin {
        name = "1password-wayland";
        paths = [ pkgs._1password-gui ];
        postBuild = ''
          rm $out/bin/1password
          cat > $out/bin/1password <<'EOF'
          #!${pkgs.runtimeShell}
          platform=wayland
          if [ -e /run/sbx/display.env ] && [ -n "''${DISPLAY:-}" ]; then platform=x11; fi
          exec ${pkgs._1password-gui}/bin/1password --ozone-platform="$platform" "$@"
          EOF
          chmod +x $out/bin/1password
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
          # An X server of its own in its VM, which 1Password then runs on
          # (the package's wrapper above): copying works only that way. The
          # host's X server isn't involved (unlike sandbox.x11Forward).
          modules.apps.onepassword.sandbox.vm.x11 = lib.mkDefault true;
          users.users."app-onepassword".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
