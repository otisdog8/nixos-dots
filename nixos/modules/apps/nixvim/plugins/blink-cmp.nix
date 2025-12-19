# Blink completion
{ lib, ... }:
{
  plugins.blink-cmp = {
    enable = true;
    lazyLoad.settings.event = [ "InsertEnter" "CmdlineEnter" ];
    settings = {
      keymap.preset = "enter";
      appearance.nerd_font_variant = "mono";
      completion.documentation = {
        auto_show = true;
        auto_show_delay_ms = 500;
      };
      signature.enabled = true;
      fuzzy.implementation = "lua";
    };
  };
}
