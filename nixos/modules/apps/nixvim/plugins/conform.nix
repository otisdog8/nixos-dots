# conform.nvim - Formatting
{ lib, ... }:
{
  plugins.conform-nvim = {
    enable = true;
    lazyLoad.settings = {
      event = "BufWritePre";
      cmd = "ConformInfo";
    };
    
    settings = {
      notify_on_error = false;
      
      format_on_save.__raw = ''
        function(bufnr)
          -- Disable format_on_save for specific filetypes
          local disable_filetypes = { c = true, cpp = true }
          if disable_filetypes[vim.bo[bufnr].filetype] then
            return nil
          else
            return {
              timeout_ms = 500,
              lsp_format = 'fallback',
            }
          end
        end
      '';
      
      formatters_by_ft = {
        lua = [ "stylua" ];
        nix = [ "nixfmt" ];
        # Add more formatters as needed
        # python = [ "isort" "black" ];
        # javascript = {
        #   __unkeyed-1 = "prettierd";
        #   __unkeyed-2 = "prettier";
        #   stop_after_first = true;
        # };
      };
    };
  };

  # Format keymap
  keymaps = [
    {
      mode = "";
      key = "<leader>f";
      action.__raw = ''
        function()
          require('conform').format({ async = true, lsp_format = 'fallback' })
        end
      '';
      options.desc = "[F]ormat buffer";
    }
  ];
}
