{ config, pkgs, ... }:

let
  FORGE_VERSION = "47.3.11";
  ATM9_VERSION = "0.3.5"; # You can change this to your desired ATM9 version
in
{
  systemd.services.atm9 = {
    description = "All The Mods 9";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = ''
        ${pkgs.screen}/bin/screen -DmS mc \
        "${pkgs.jdk}/bin/java" \
        @user_jvm_args.txt \
        @libraries/net/minecraftforge/forge/1.20.1-${FORGE_VERSION}/unix_args.txt nogui
      '';
      ExecStop = ''
        ${pkgs.screen}/bin/screen -S mc -X stuff "save-all^M" \
        /bin/sleep 5 \
        ${pkgs.screen}/bin/screen -S mc -X stuff "stop^M" \
        /bin/sleep 5
      '';
      User = "mc";
      Group = "mc";
      WorkingDirectory = "/mc/atm9-${ATM9_VERSION}";
    };
  };

  users.users.mc = {
    isSystemUser = true;
    description = "For Minecraft Servers";
    group = "mc";
    shell = pkgs.bash;
    home = "/mc";
  };
  users.groups.mc = { };

}
