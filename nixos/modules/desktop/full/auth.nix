# Authentication configuration - 1Password, KWallet, polkit
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.modules.desktop.full.auth;
in
{
  # The 1Password GUI is now a dedicated-uid sandbox app (vault hidden from jrt) rather
  # than programs._1password-gui — see ../../apps/onepassword.nix.
  imports = [ ../../apps/onepassword.nix ];

  options.modules.desktop.full.auth = {
    enable = lib.mkEnableOption "authentication configuration";
  };

  config = lib.mkIf cfg.enable {
    # Sandboxed 1Password GUI (systemd dedicated-uid). Its .config/1Password + .1password
    # move to an app-onepassword-owned stash (hidden from jrt); the migration handles the
    # move on switch (quit 1Password first for a clean migrate).
    modules.apps.onepassword.enable = true;

    environment = {
      # 1Password is ONLY the sandboxed GUI (app module above). No _1password-cli and no
      # programs._1password* at all — the goal is a very-protected GUI, not tooling. Only
      # the (unrelated) kwallet packages remain here.
      systemPackages = with pkgs; [
        kdePackages.kwallet
        kdePackages.kwallet-pam
        kdePackages.kwalletmanager
      ];

      # NB: no /persist entries for .config/1Password or .1password anymore — they're
      # app-onepassword stash entries (onepassword.nix), not jrt-visible home dirs.
      persistence."/persist" = {
        users.${username} = {
          directories = [
            {
              directory = ".local/share/kwalletd/";
              mode = "0700";
            }
          ];
          files = [
            ".kwalletrc"
          ];
        };
      };
    };

    # NB: both programs._1password (CLI) and programs._1password-gui are intentionally
    # ABSENT. The GUI module (dedicated-uid sandbox) is the entire 1Password footprint;
    # programs._1password-gui only exists for browser integration + the setuid
    # BrowserSupport helper + system-auth-unlock polkit, none of which we want. Unlock is
    # by the account master password, and the GUI stays fully inside its sandbox.

    # Security configuration
    security = {
      # Polkit
      polkit.enable = true;

      # KWallet PAM integration
      pam.services = {
        sddm.enableKwallet = true;
        login.kwallet = {
          enable = true;
          package = pkgs.kdePackages.kwallet-pam;
        };
        kde = {
          allowNullPassword = true;
          kwallet = {
            enable = true;
            package = pkgs.kdePackages.kwallet-pam;
          };
        };
        kwallet = {
          name = "kwallet";
          enableKwallet = true;
        };
      };
    };
  };
}
