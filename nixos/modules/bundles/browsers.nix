# Browser applications bundle
{ config, lib, ... }:
let
  cfg = config.modules.bundles.browsers;
in
{
  imports = [
    ../apps/zen-browser.nix
    ../apps/firefox.nix
    ../apps/brave.nix
    ../apps/chromium.nix
    ../apps/ungoogled-chromium.nix
  ];

  options.modules.bundles.browsers = {
    enable = lib.mkEnableOption "browser applications bundle";

    zen-browser.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Zen Browser";
    };

    firefox.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Firefox";
    };

    brave.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Brave";
    };

    chromium.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Chromium";
    };

    ungoogled-chromium.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Ungoogled Chromium (ephemeral, tmpfs homedir)";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.apps = {
      zen-browser = {
        inherit (cfg.zen-browser) enable;
        isDefaultBrowser = lib.mkDefault true;
      };

      firefox = {
        inherit (cfg.firefox) enable;
      };

      brave = {
        inherit (cfg.brave) enable;
      };

      chromium = {
        inherit (cfg.chromium) enable;
      };

      ungoogled-chromium = {
        inherit (cfg.ungoogled-chromium) enable;
      };
    };
  };
}
