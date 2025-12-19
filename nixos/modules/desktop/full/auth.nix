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
  options.modules.desktop.full.auth = {
    enable = lib.mkEnableOption "authentication configuration";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      _1password-cli
      _1password-gui
      kdePackages.kwallet
      kdePackages.kwallet-pam
      kdePackages.kwalletmanager
    ];

    environment.etc = {
      "1password/custom_allowed_browsers" = {
        text = ''
          zen
          firefox
          brave
          chromium
          .zen-wrapped
          .firefox-wrapped
          .brave-wrapped
          .chromium-wrapped
        '';
        mode = "0755";
      };
    };

    # 1Password
    programs._1password.enable = true;
    programs._1password-gui = {
      enable = true;
      polkitPolicyOwners = [ "jrt" ];
    };

    # Polkit
    security.polkit.enable = true;

    # KWallet PAM integration
    security.pam.services.sddm.enableKwallet = true;
    security.pam.services = {
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
    };
    security.pam.services.kwallet = {
      name = "kwallet";
      enableKwallet = true;
    };

    # Persistence for authentication
    environment.persistence."/persist" = {
      users.${username} = {
        directories = [
          {
            directory = ".config/1Password";
            mode = "0700";
          }
          {
            directory = ".1password";
            mode = "0700";
          }
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
}
