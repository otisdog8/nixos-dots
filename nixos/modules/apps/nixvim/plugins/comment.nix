# Smart commenting with treesitter support
{ lib, ... }:
{
  # ts-context-commentstring for treesitter-aware commenting
  plugins.ts-context-commentstring = {
    enable = true;
    skipTsContextCommentStringModule = true;
    settings = {
      enable_autocmd = false; # Let comment.nvim handle this
    };
  };

  # Comment.nvim for powerful commenting
  plugins.comment = {
    enable = true;
    lazyLoad.settings.event = "VimEnter";
    
    settings = {
      padding = true;
      sticky = true;
      ignore = null;
      
      # Default keymaps
      toggler = {
        line = "gcc";
        block = "gbc";
      };
      
      opleader = {
        line = "gc";
        block = "gb";
      };
      
      extra = {
        above = "gcO";
        below = "gco";
        eol = "gcA";
      };
      
      mappings = {
        basic = true;
        extra = true;
      };
      
      # Integrate with ts-context-commentstring
      pre_hook = lib.nixvim.mkRaw ''
        require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook()
      '';
    };
  };
}
