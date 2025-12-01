{ config, pkgs, ... }:

let
  FORGE_VERSION = "47.3.11";
  ATM9_VERSION = "0.3.5";
in
{
  imports = [ ../modules/apps/minecraft-server.nix ];

  modules.apps.minecraft-server = {
    enable = true;

    servers.atm9 = {
      enable = false;
      directory = "/mc/atm9-${ATM9_VERSION}";
      javaPackage = pkgs.jdk;
      jvmArgsFile = "@user_jvm_args.txt";
      extraArgs = [ "@libraries/net/minecraftforge/forge/1.20.1-${FORGE_VERSION}/unix_args.txt" ];
      jar = null;
      openFirewall = true;
    };

    servers.sdfs = {
      enable = true;
      directory = "/mc/sdfs";
      jvmArgsFile = "@user_jvm_args.txt";
      jar = "paper.jar";
      openFirewall = true;
    };
  };
}
