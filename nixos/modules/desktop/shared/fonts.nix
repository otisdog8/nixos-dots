# Font configuration
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.desktop.shared.fonts;
in
{
  options.modules.desktop.shared.fonts = {
    enable = lib.mkEnableOption "font configuration";
  };

  config = lib.mkIf cfg.enable {
    fonts.packages =
      with pkgs;
      [
        liberation_ttf
        roboto
        sarasa-gothic
        noto-fonts
        noto-fonts-color-emoji
        fira-code
        fira-code-symbols
        gyre-fonts
      ]
      ++ builtins.filter lib.attrsets.isDerivation (builtins.attrValues pkgs.nerd-fonts);

    fonts.enableDefaultPackages = true;
  };
}
