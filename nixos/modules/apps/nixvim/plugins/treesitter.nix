# Treesitter syntax highlighting
{ lib, ... }:
{
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
