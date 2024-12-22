{
  config,
  hostname,
  inputs,
  lib,
  modulesPath,
  outputs,
  pkgs,
  platform,
  stateVersion,
  username,
  ...
}:

{
  services.tailscale.enable = true;
  services.tailscale.openFirewall = true;
  environment.enableDebugInfo = true;
  
  services.openssh = {
    enable = true;
    ports = [ 22 ];
    settings = {
      PasswordAuthentication = true;
      AllowUsers = null; # Allows all users by default. Can be [ "user1" "user2" ]
      UseDns = true;
      X11Forwarding = false;
      PermitRootLogin = "no"; # "yes", "without-password", "prohibit-password", "forced-commands-only", "no"
    };
  };
  services.fail2ban= {
    enable = true;
  };
  networking.firewall.allowedTCPPorts = [ 22 ];
  networking.firewall.enable = true;
}
