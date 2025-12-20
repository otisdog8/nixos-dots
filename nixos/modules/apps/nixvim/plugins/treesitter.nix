# Treesitter syntax highlighting
{ lib, ... }:
{
  # Prevent treesitter from being combined to avoid query conflicts with other plugins
  performance.combinePlugins.standalonePlugins = [ "nvim-treesitter" ];
  
  plugins.treesitter = {
    enable = true;
    lazyLoad.settings.event = [
      "BufReadPost"
      "BufNewFile"
    ];
    settings = {
      highlight.enable = true;
      indent.enable = true;
    };
  };
}
