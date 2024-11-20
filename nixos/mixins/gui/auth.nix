{ inputs, lib, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # Apps
    inputs.zen-browser.packages."${system}".default
    _1password
    _1password-gui

    # Desktop
    kdePackages.kwallet
    polkit-kde-agent
    kwallet-pam
    kwalletmanager
  ];

    environment.etc = {
      "1password/custom_allowed_browsers" = {
        text = ''
          .zen-wrapped
        '';
        mode = "0755";
      };
    };
  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "jrt" ];
  };
  security.polkit.enable = true;

  security.pam.services.sddm.enableKwallet = true;
  security.pam.services = {
   login.kwallet = {
     enable = true;
     package = pkgs.kwallet-pam;
   };
   kde = {
     allowNullPassword = true;
     kwallet = {
       enable = true;
       package = pkgs.kwallet-pam;
     };
   };
  };
  security.pam.services.kwallet = {
  name = "kwallet";
  enableKwallet = true;
  };

  systemd = {
  user.services.polkit-kde-authentication-agent-1 = {
    description = "polkit-kde-authentication-agent-1";
    wantedBy = [ "graphical-session.target" ];
    wants = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.polkit-kde-agent}/libexec/polkit-kde-authentication-agent-1";
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 10;
      };
  };
  };
}
