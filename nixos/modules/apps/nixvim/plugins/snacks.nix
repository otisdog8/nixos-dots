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
    };
  };

  keymaps = [
    # File/buffer navigation
    { mode = "n"; key = "<leader>sh"; action.__raw = "function() Snacks.picker.help() end"; options.desc = "[S]earch [H]elp"; }
    { mode = "n"; key = "<leader>sk"; action.__raw = "function() Snacks.picker.keymaps() end"; options.desc = "[S]earch [K]eymaps"; }
    { mode = "n"; key = "<leader>sf"; action.__raw = "function() Snacks.picker.files() end"; options.desc = "[S]earch [F]iles"; }
    { mode = "n"; key = "<leader>ss"; action.__raw = "function() Snacks.picker() end"; options.desc = "[S]earch [S]elect Picker"; }
    { mode = "n"; key = "<leader>sw"; action.__raw = "function() Snacks.picker.grep_word() end"; options.desc = "[S]earch current [W]ord"; }
    { mode = "n"; key = "<leader>sg"; action.__raw = "function() Snacks.picker.grep() end"; options.desc = "[S]earch by [G]rep"; }
    { mode = "n"; key = "<leader>sd"; action.__raw = "function() Snacks.picker.diagnostics() end"; options.desc = "[S]earch [D]iagnostics"; }
    { mode = "n"; key = "<leader>sr"; action.__raw = "function() Snacks.picker.resume() end"; options.desc = "[S]earch [R]esume"; }
    { mode = "n"; key = "<leader>s."; action.__raw = "function() Snacks.picker.recent() end"; options.desc = "[S]earch Recent Files"; }
    { mode = "n"; key = "<leader><leader>"; action.__raw = "function() Snacks.picker.buffers() end"; options.desc = "Find existing buffers"; }

    # Search in buffer
    { mode = "n"; key = "<leader>/"; action.__raw = "function() Snacks.picker.lines() end"; options.desc = "[/] Fuzzily search in current buffer"; }

    # Search in open files
    { mode = "n"; key = "<leader>s/"; action.__raw = "function() Snacks.picker.grep_buffers() end"; options.desc = "[S]earch [/] in Open Files"; }

    # Search neovim config
    { mode = "n"; key = "<leader>sn"; action.__raw = "function() Snacks.picker.files({ cwd = vim.fn.stdpath('config') }) end"; options.desc = "[S]earch [N]eovim files"; }

    # Note: LSP keybinds (gd, gr, gI, etc.) are now in lsp.nix via LspAttach autocmd
  ];
}
