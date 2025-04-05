{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages = with pkgs; [
    # Apps
    inputs.zen-browser.packages."${system}".default
    _1password
    _1password-gui

    # Desktop
    kdePackages.kwallet
    kdePackages.kwallet-pam
    kdePackages.kwalletmanager
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
}
