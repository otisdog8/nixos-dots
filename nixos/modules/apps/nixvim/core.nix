# Core nixvim settings
{ lib, ... }:
{
  # Lazy loading provider
  plugins.lz-n.enable = true;

  # Performance optimizations
  performance = {
    byteCompileLua.enable = true;
    combinePlugins.enable = true;
  };

  clipboard.register = "unnamedplus";
  # The sandbox has no Wayland socket (nixvim.nix), so wl-copy can't work. Copy
  # through the terminal with OSC 52 instead. Paste returns nvim's own last copy:
  # reading the clipboard over OSC 52 makes kitty ask every time, and text from
  # other apps comes in through the terminal's own paste (ctrl+shift+v) anyway.
  extraConfigLuaPre = ''
    do
      local osc52 = require("vim.ui.clipboard.osc52")
      local last = { ["+"] = { {}, "v" }, ["*"] = { {}, "v" } }
      local function copy(reg)
        local send = osc52.copy(reg)
        return function(lines, regtype)
          last[reg] = { lines, regtype }
          send(lines, regtype)
        end
      end
      local function paste(reg)
        return function() return last[reg] end
      end
      vim.g.clipboard = {
        name = "OSC 52 (copy only)",
        copy = { ["+"] = copy("+"), ["*"] = copy("*") },
        paste = { ["+"] = paste("+"), ["*"] = paste("*") },
      }
    end
  '';
  colorscheme = "catppuccin";
  globals.mapleader = " ";

  opts = {
    # Line numbers
    number = true; # Show line numbers
    relativenumber = true; # Show relative line numbers for easier jumping

    # Indentation
    shiftwidth = 2; # Number of spaces for indentation
    tabstop = 2; # Number of spaces a tab counts for
    breakindent = true; # Wrap indent to match line start

    # Mouse support
    mouse = "a"; # Enable mouse for resizing splits, etc.

    # Clipboard integration (already set via clipboard.register)

    # Undo
    undofile = true; # Save undo history to file

    # Search
    ignorecase = true; # Case-insensitive search...
    smartcase = true; # ...unless query has capitals
    inccommand = "split"; # Preview substitutions live in split window

    # UI
    signcolumn = "yes"; # Always show sign column (prevents text shift)
    cursorline = true; # Highlight the line the cursor is on
    scrolloff = 10; # Min lines to keep above/below cursor
    showmode = false; # Don't show mode (already in statusline)

    # Splits
    splitright = true; # Vertical splits open to the right
    splitbelow = true; # Horizontal splits open below

    # Timing
    updatetime = 250; # Faster completion (default 4000ms)
    timeoutlen = 300; # Faster mapped sequence wait time

    # Whitespace visualization
    list = true;
    listchars = "tab:→ ,trail:·,extends:⟩,precedes:⟨";

    # Confirmation dialogs
    confirm = true; # Ask to save instead of failing commands
  };

  dependencies = {
    ripgrep.enable = true;
    git.enable = true;
  };
}
