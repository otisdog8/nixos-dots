# Indent guides with rainbow colors
{ lib, ... }:
{
  plugins.indent-blankline = {
    enable = true;
    
    # Lazy load on buffer read for better startup performance
    lazyLoad.settings.event = [ "BufReadPost" "BufNewFile" ];
    
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

  # Define the rainbow highlight groups and register hooks
  # Set them up on VimEnter and when colorscheme changes
  autoGroups.ibl_rainbow_setup.clear = true;
  
  autoCmd = [
    {
      event = [ "VimEnter" "ColorScheme" ];
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
      event = "LspAttach";
      group = "ibl_rainbow_setup";
      callback = lib.nixvim.mkRaw ''
        function()
          -- Register the scope highlight hook after IBL is loaded
          local ok, hooks = pcall(require, 'ibl.hooks')
          if ok then
            hooks.register(hooks.type.SCOPE_HIGHLIGHT, hooks.builtin.scope_highlight_from_extmark)
          end
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
