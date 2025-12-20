# Blink completion
{ config, lib, pkgs, ... }:
{
  plugins.blink-cmp = {
    enable = true;
    lazyLoad.settings.event = [
      "InsertEnter"
      "CmdlineEnter"
    ];
    settings = {
      keymap = {
        preset = "enter";
        # Manual Minuet completion trigger
        "<A-y>" = lib.nixvim.mkRaw "require('minuet').make_blink_map()";
      };
      
      appearance.nerd_font_variant = "mono";
      
      completion = {
        documentation = {
          auto_show = true;
          auto_show_delay_ms = 500;
        };
        # Recommended: avoid unnecessary requests
        trigger.prefetch_on_insert = false;
      };
      
      signature.enabled = true;
      fuzzy.implementation = "lua";
      
      # Sources configuration
      sources = {
        default = [
          "lsp"
          "path"
          "snippets"
          "buffer"
          "minuet" # AI completion
        ];
        
        per_filetype = {
          codecompanion = [ "codecompanion" ];
        };
        
        providers = {
          # Minuet AI completion
          minuet = {
            name = "minuet";
            module = "minuet.blink";
            async = true;
            timeout_ms = 3000; # Match minuet request_timeout
            score_offset = 50; # Higher priority
          };
        };
      };
    };
  };
}
