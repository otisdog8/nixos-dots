# Git signs in the gutter
{ lib, ... }:
{
  plugins.gitsigns = {
    enable = true;
    lazyLoad.settings.event = [ "BufReadPre" "BufNewFile" ];
    settings = {
      signs = {
        add = { text = "+"; };
        change = { text = "~"; };
        delete = { text = "_"; };
        topdelete = { text = "‾"; };
        changedelete = { text = "~"; };
      };
    };
  };
}
