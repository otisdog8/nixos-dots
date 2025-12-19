# Rainbow delimiters for Neovim with Tree-sitter
{ lib, ... }:
{
  plugins.rainbow-delimiters = {
    enable = true;
    
    # Lazy load on UI enter for better startup performance
    lazyLoad.settings.event = [ "BufReadPost" "BufNewFile" ];
    
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
