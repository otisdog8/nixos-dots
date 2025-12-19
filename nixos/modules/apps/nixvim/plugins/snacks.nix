# Snacks.nvim - picker and utilities
{ lib, ... }:
{
  plugins.snacks = {
    enable = true;
    settings = {
      picker.enabled = true;
      notifier.enabled = true;
      quickfile.enabled = true;
      input.enabled = true;
      bigfile.enabled = true;
      dashboard.enabled = true;
      
      # Bigfile optimization settings
      bigfile = {
        notify = true; # Show notification when big file is detected
        size = 1024 * 1024; # 1MB threshold
        
        # Disable heavy features for big files
        setup = lib.nixvim.mkRaw ''
          function(ctx)
            -- Disable indent-blankline for big files
            vim.schedule(function()
              local ok, ibl = pcall(require, "ibl")
              if ok then
                ibl.setup_buffer(0, { enabled = false })
              end
            end)
            
            -- Disable syntax highlighting
            vim.cmd("syntax off")
            vim.opt_local.syntax = "off"
            
            -- Disable swap file
            vim.opt_local.swapfile = false
            
            -- Disable undo file
            vim.opt_local.undofile = false
            
            -- Set buffer as readonly for safety
            vim.opt_local.readonly = true
            
            -- Disable foldmethod
            vim.opt_local.foldmethod = "manual"
          end
        '';
      };
      
      # Dashboard configuration - "files" example
      dashboard = {
        preset = {
          keys = [
            { icon = " "; key = "f"; desc = "Find File"; action = lib.nixvim.mkRaw ''function() Snacks.dashboard.pick('files') end''; }
            { icon = " "; key = "n"; desc = "New File"; action = ":ene | startinsert"; }
            { icon = " "; key = "g"; desc = "Find Text"; action = lib.nixvim.mkRaw ''function() Snacks.dashboard.pick('live_grep') end''; }
            { icon = " "; key = "r"; desc = "Recent Files"; action = lib.nixvim.mkRaw ''function() Snacks.dashboard.pick('oldfiles') end''; }
            { icon = " "; key = "c"; desc = "Config"; action = lib.nixvim.mkRaw ''function() Snacks.dashboard.pick('files', {cwd = vim.fn.stdpath('config')}) end''; }
            { icon = " "; key = "q"; desc = "Quit"; action = ":qa"; }
          ];
          header = ''
            ███╗   ██╗███████╗ ██████╗ ██╗   ██╗██╗███╗   ███╗
            ████╗  ██║██╔════╝██╔═══██╗██║   ██║██║████╗ ████║
            ██╔██╗ ██║█████╗  ██║   ██║██║   ██║██║██╔████╔██║
            ██║╚██╗██║██╔══╝  ██║   ██║╚██╗ ██╔╝██║██║╚██╔╝██║
            ██║ ╚████║███████╗╚██████╔╝ ╚████╔╝ ██║██║ ╚═╝ ██║
            ╚═╝  ╚═══╝╚══════╝ ╚═════╝   ╚═══╝  ╚═╝╚═╝     ╚═╝'';
        };
        sections = [
          { section = "header"; }
          { section = "keys"; gap = 1; }
          { icon = " "; title = "Recent Files"; section = "recent_files"; indent = 2; padding = { __unkeyed-1 = 2; __unkeyed-2 = 2; }; }
          { icon = " "; title = "Projects"; section = "projects"; indent = 2; padding = 2; }
        ];
      };
    };
  };

  keymaps = [
    # File/buffer navigation
    {
      mode = "n";
      key = "<leader>sh";
      action.__raw = "function() Snacks.picker.help() end";
      options.desc = "[S]earch [H]elp";
    }
    {
      mode = "n";
      key = "<leader>sk";
      action.__raw = "function() Snacks.picker.keymaps() end";
      options.desc = "[S]earch [K]eymaps";
    }
    {
      mode = "n";
      key = "<leader>sf";
      action.__raw = "function() Snacks.picker.files() end";
      options.desc = "[S]earch [F]iles";
    }
    {
      mode = "n";
      key = "<leader>ss";
      action.__raw = "function() Snacks.picker() end";
      options.desc = "[S]earch [S]elect Picker";
    }
    {
      mode = "n";
      key = "<leader>sw";
      action.__raw = "function() Snacks.picker.grep_word() end";
      options.desc = "[S]earch current [W]ord";
    }
    {
      mode = "n";
      key = "<leader>sg";
      action.__raw = "function() Snacks.picker.grep() end";
      options.desc = "[S]earch by [G]rep";
    }
    {
      mode = "n";
      key = "<leader>sd";
      action.__raw = "function() Snacks.picker.diagnostics() end";
      options.desc = "[S]earch [D]iagnostics";
    }
    {
      mode = "n";
      key = "<leader>sr";
      action.__raw = "function() Snacks.picker.resume() end";
      options.desc = "[S]earch [R]esume";
    }
    {
      mode = "n";
      key = "<leader>s.";
      action.__raw = "function() Snacks.picker.recent() end";
      options.desc = "[S]earch Recent Files";
    }
    {
      mode = "n";
      key = "<leader><leader>";
      action.__raw = "function() Snacks.picker.buffers() end";
      options.desc = "Find existing buffers";
    }

    # Search in buffer
    {
      mode = "n";
      key = "<leader>/";
      action.__raw = "function() Snacks.picker.lines() end";
      options.desc = "[/] Fuzzily search in current buffer";
    }

    # Search in open files
    {
      mode = "n";
      key = "<leader>s/";
      action.__raw = "function() Snacks.picker.grep_buffers() end";
      options.desc = "[S]earch [/] in Open Files";
    }

    # Search neovim config
    {
      mode = "n";
      key = "<leader>sn";
      action.__raw = "function() Snacks.picker.files({ cwd = vim.fn.stdpath('config') }) end";
      options.desc = "[S]earch [N]eovim files";
    }

    # Note: LSP keybinds (gd, gr, gI, etc.) are now in lsp.nix via LspAttach autocmd
  ];
}
