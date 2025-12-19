# Core nixvim settings
{ lib, ... }:
{
  # Lazy loading provider
  plugins.lz-n.enable = true;

  # Performance optimizations
  performance = {
    byteCompileLua.enable = true;
    combinePlugins.enable = true;
  };

  clipboard.register = "unnamedplus";
  colorscheme = "catppuccin";
  globals.mapleader = " ";

  opts = {
    number = true;
    relativenumber = true;
    shiftwidth = 2;
    tabstop = 2;
  };

  dependencies = {
    ripgrep.enable = true;
    git.enable = true;
  };
}
