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
  ];

  options.modules.bundles.browsers = {
    enable = lib.mkEnableOption "browser applications bundle";

    enableSandboxing = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable sandboxing for all browsers in the bundle";
    };

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
      default = true;
      description = "Enable Brave";
    };

    chromium.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Chromium";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.apps.zen-browser = {
      enable = cfg.zen-browser.enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
      isDefaultBrowser = lib.mkDefault true;
    };

    modules.apps.firefox = {
      enable = cfg.firefox.enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
    };

    modules.apps.brave = {
      enable = cfg.brave.enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
    };

    modules.apps.chromium = {
      enable = cfg.chromium.enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
    };
  };
}
