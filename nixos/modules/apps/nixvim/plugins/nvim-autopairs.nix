# Autopairs - automatically insert and delete brackets, parens, quotes in pairs
{ lib, ... }:
{
  plugins.nvim-autopairs = {
    enable = true;
    lazyLoad.settings.event = "InsertEnter";
    settings = { };
  };
}
