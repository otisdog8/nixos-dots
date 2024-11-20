{ inputs, lib, pkgs, ... }:
{

  fonts.packages = with pkgs; [
    nerdfonts
    texlivePackages.fontawesome
    liberation_ttf
    roboto
    sarasa-gothic
    noto-fonts
    noto-fonts-emoji
    liberation_ttf
    fira-code
    fira-code-symbols
    gyre-fonts
  ];
  fonts.enableDefaultPackages = true;


}
