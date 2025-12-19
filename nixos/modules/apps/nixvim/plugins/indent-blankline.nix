# Indent guides with rainbow colors
{ lib, ... }:
{
  # Define the rainbow highlight groups BEFORE the plugin loads
  extraConfigLuaPre = ''
    vim.api.nvim_set_hl(0, 'RainbowRed', { fg = '#E06C75' })
    vim.api.nvim_set_hl(0, 'RainbowYellow', { fg = '#E5C07B' })
    vim.api.nvim_set_hl(0, 'RainbowBlue', { fg = '#61AFEF' })
    vim.api.nvim_set_hl(0, 'RainbowOrange', { fg = '#D19A66' })
    vim.api.nvim_set_hl(0, 'RainbowGreen', { fg = '#98C379' })
    vim.api.nvim_set_hl(0, 'RainbowViolet', { fg = '#C678DD' })
    vim.api.nvim_set_hl(0, 'RainbowCyan', { fg = '#56B6C2' })
  '';

  plugins.indent-blankline = {
    enable = true;
    
    settings = {
      indent = {
        highlight = [
          "RainbowRed"
          "RainbowYellow"
          "RainbowBlue"
          "RainbowOrange"
          "RainbowGreen"
          "RainbowViolet"
          "RainbowCyan"
        ];
      };
      scope = {
        enabled = true;
        show_start = true;
        show_end = false;
      };
      exclude = {
        buftypes = [ "terminal" "nofile" ];
        filetypes = [
          "help"
          "alpha"
          "dashboard"
          "snacks_dashboard"
          "neo-tree"
          "Trouble"
          "lazy"
          "mason"
          "notify"
          "toggleterm"
        ];
      };
    };
  };

  # Update highlight groups when colorscheme changes and register hooks
  autoGroups.ibl_rainbow_setup.clear = true;
  
  autoCmd = [
    {
      event = "ColorScheme";
      group = "ibl_rainbow_setup";
      callback = lib.nixvim.mkRaw ''
        function()
          vim.api.nvim_set_hl(0, 'RainbowRed', { fg = '#E06C75' })
          vim.api.nvim_set_hl(0, 'RainbowYellow', { fg = '#E5C07B' })
          vim.api.nvim_set_hl(0, 'RainbowBlue', { fg = '#61AFEF' })
          vim.api.nvim_set_hl(0, 'RainbowOrange', { fg = '#D19A66' })
          vim.api.nvim_set_hl(0, 'RainbowGreen', { fg = '#98C379' })
          vim.api.nvim_set_hl(0, 'RainbowViolet', { fg = '#C678DD' })
          vim.api.nvim_set_hl(0, 'RainbowCyan', { fg = '#56B6C2' })
        end
      '';
    }
    {
      event = "VimEnter";
      group = "ibl_rainbow_setup";
      once = true;
      callback = lib.nixvim.mkRaw ''
        function()
          -- Register the scope highlight hook after IBL is loaded
          vim.schedule(function()
            local ok, hooks = pcall(require, 'ibl.hooks')
            if ok then
              hooks.register(hooks.type.SCOPE_HIGHLIGHT, hooks.builtin.scope_highlight_from_extmark)
            end
          end)
        end
      '';
    }
  ];
  
  # Toggle keymap
  keymaps = [
    {
      mode = "n";
      key = "<leader>ui";
      action = "<cmd>IBLToggle<CR>";
      options.desc = "Toggle Indent Guides";
    }
  ];
}
