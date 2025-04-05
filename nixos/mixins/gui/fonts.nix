{
  inputs,
  lib,
  pkgs,
  ...
}:
{

  fonts.packages =
    with pkgs;
    [
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
    ]
    ++ builtins.filter lib.attrsets.isDerivation (builtins.attrValues pkgs.nerd-fonts);
  fonts.enableDefaultPackages = true;

}
