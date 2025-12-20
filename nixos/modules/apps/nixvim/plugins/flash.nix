# Navigate with search labels and enhanced motions
{ lib, ... }:
{
  plugins.flash = {
    enable = true;

    settings = {
      labels = "asdfghjklqwertyuiopzxcvbnm";

      # Enable search integration
      modes = {
        search = {
          enabled = true;
          highlight.backdrop = false;
          jump = {
            history = true;
            register = true;
            nohlsearch = true;
          };
        };

        # Enhanced f/t/F/T motions
        char = {
          enabled = true;
          jump_labels = false;
          multi_line = true;
          label.exclude = "hjkliardc";
          keys = {
            f = "f";
            F = "F";
            t = "t";
            T = "T";
            ";" = ";";
            "," = ",";
          };
          char_actions = lib.nixvim.mkRaw ''
            function(motion)
              return {
                [";"] = "next",
                [","] = "prev",
                [motion:lower()] = "next",
                [motion:upper()] = "prev",
              }
            end
          '';
          search.wrap = false;
          highlight.backdrop = true;
        };

        # Treesitter mode
        treesitter = {
          labels = "abcdefghijklmnopqrstuvwxyz";
          jump = {
            pos = "range";
            autojump = true;
          };
          search.incremental = false;
          label = {
            before = true;
            after = true;
            style = "inline";
          };
          highlight = {
            backdrop = false;
            matches = false;
          };
        };

        # Treesitter search mode
        treesitter_search = {
          jump.pos = "range";
          search = {
            multi_window = true;
            wrap = true;
            incremental = false;
          };
          remote_op.restore = true;
          label = {
            before = true;
            after = true;
            style = "inline";
          };
        };
      };
    };
  };

  # Keybindings
  keymaps = [
    # Flash jump
    {
      mode = [
        "n"
        "x"
        "o"
      ];
      key = "<leader>j";
      action = lib.nixvim.mkRaw "function() require('flash').jump() end";
      options.desc = "Flash";
    }

    # Flash treesitter
    {
      mode = [
        "n"
        "x"
        "o"
      ];
      key = "<leader>t";
      action = lib.nixvim.mkRaw "function() require('flash').treesitter() end";
      options.desc = "Flash Treesitter";
    }

    # Remote flash (operator pending)
    {
      mode = "o";
      key = "r";
      action = lib.nixvim.mkRaw "function() require('flash').remote() end";
      options.desc = "Remote Flash";
    }

    # Treesitter search
    {
      mode = [
        "o"
        "x"
      ];
      key = "R";
      action = lib.nixvim.mkRaw "function() require('flash').treesitter_search() end";
      options.desc = "Treesitter Search";
    }

    # Toggle flash search in command mode
    {
      mode = "c";
      key = "<c-s>";
      action = lib.nixvim.mkRaw "function() require('flash').toggle() end";
      options.desc = "Toggle Flash Search";
    }
  ];
}
