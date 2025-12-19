# Media applications bundle
{ config, lib, ... }:
let
  cfg = config.modules.bundles.media;
in
{
  imports = [
    ../apps/obs-studio.nix
  ];

  options.modules.bundles.media = {
    enable = lib.mkEnableOption "media applications bundle";

    enableSandboxing = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable sandboxing for all media apps in the bundle";
    };

    obs-studio.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable OBS Studio";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.apps.obs-studio = {
      inherit (cfg.obs-studio) enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
    };
  };
}
