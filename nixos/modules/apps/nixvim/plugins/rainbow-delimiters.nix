# Rainbow delimiters for Neovim with Tree-sitter
{ lib, ... }:
{
  plugins.rainbow-delimiters = {
    enable = true;
    
    settings = {
      highlight = [
        "RainbowRed"
        "RainbowYellow"
        "RainbowBlue"
        "RainbowOrange"
        "RainbowGreen"
        "RainbowViolet"
        "RainbowCyan"
      ];
    };
  };
}
