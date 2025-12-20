# vim-illuminate - Automatically highlight references to word under cursor
{ lib, ... }:
{
  plugins.illuminate = {
    enable = true;

    # Lazy load on buffer read
    lazyLoad.settings.event = [
      "BufReadPost"
      "BufNewFile"
    ];

    settings = {
      # Providers: ordered by priority
      providers = [
        "lsp"
        "treesitter"
        "regex"
      ];

      # Delay in milliseconds before highlighting
      delay = 200;

      # Large file handling
      large_file_cutoff = 10000;
      large_file_overrides = {
        providers = [ "lsp" ];
      };

      # Filetypes to exclude
      filetypes_denylist = [
        "dirbuf"
        "dirvish"
        "fugitive"
        "help"
        "alpha"
        "dashboard"
        "neo-tree"
        "Trouble"
        "lazy"
        "mason"
        "notify"
        "toggleterm"
      ];

      # Highlight word under cursor
      under_cursor = true;

      # Minimum number of matches to highlight
      min_count_to_highlight = 1;
    };
  };

  # Navigation keymaps for references
  keymaps = [
    {
      mode = "n";
      key = "]]";
      action = lib.nixvim.mkRaw ''
        function()
          require('illuminate').goto_next_reference(false)
        end
      '';
      options.desc = "Next Reference";
    }
    {
      mode = "n";
      key = "[[";
      action = lib.nixvim.mkRaw ''
        function()
          require('illuminate').goto_prev_reference(false)
        end
      '';
      options.desc = "Prev Reference";
    }
  ];

  # Also set keymaps after loading ftplugins, since many overwrite [[ and ]]
  autoCmd = [
    {
      event = "FileType";
      callback = lib.nixvim.mkRaw ''
        function()
          local buffer = vim.api.nvim_get_current_buf()
          vim.keymap.set('n', ']]', function()
            require('illuminate').goto_next_reference(false)
          end, { desc = 'Next Reference', buffer = buffer })
          vim.keymap.set('n', '[[', function()
            require('illuminate').goto_prev_reference(false)
          end, { desc = 'Prev Reference', buffer = buffer })
        end
      '';
    }
  ];
}
