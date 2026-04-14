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
          local disable_filetypes = {}
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
        c = [ "clang-format" ];
        cpp = [ "clang-format" ];
        lua = [ "stylua" ];
        nix = [ "nixfmt" ];
        yaml = [ "yamlfmt" ];
        sh = [ "shfmt" ];
        bash = [ "shfmt" ];
        markdown = [ "markdownlint" ];
        javascript = [ "prettierd" ];
        javascriptreact = [ "prettierd" ];
        typescript = [ "prettierd" ];
        typescriptreact = [ "prettierd" ];
        json = [ "prettierd" ];
        css = [ "prettierd" ];
        html = [ "prettierd" ];
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
