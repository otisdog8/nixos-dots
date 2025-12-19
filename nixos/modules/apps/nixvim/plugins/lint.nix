# nvim-lint - Linting
{ lib, ... }:
{
  plugins.lint = {
    enable = true;
    lazyLoad.settings.event = [
      "BufReadPre"
      "BufNewFile"
    ];

    lintersByFt = {
      markdown = [ "markdownlint" ];
      nix = [ "statix" ];
      # Add other linters as needed
      # python = [ "pylint" ];
      # javascript = [ "eslint" ];
      # typescript = [ "eslint" ];
    };

    # Disable the default autoCmd (we'll set it up in luaConfig.post)
    autoCmd = null;

    # Set up autocmd after plugin loads
    luaConfig.post = ''
      local lint_augroup = vim.api.nvim_create_augroup('lint', { clear = true })
      vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'InsertLeave' }, {
        group = lint_augroup,
        callback = function()
          if vim.bo.modifiable then
            require('lint').try_lint()
          end
        end,
      })
    '';
  };
}
