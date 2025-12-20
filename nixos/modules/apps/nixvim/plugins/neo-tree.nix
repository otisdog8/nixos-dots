# File system browser
{ lib, ... }:
{
  plugins.neo-tree = {
    enable = true;
    lazyLoad.settings.cmd = "Neotree";

    settings = {
      close_if_last_window = false;
      popup_border_style = "rounded";

      filesystem = {
        window = {
          mappings = {
            "<leader>e" = "close_window";
          };
        };
        follow_current_file = {
          enabled = true;
          leave_dirs_open = false;
        };
        use_libuv_file_watcher = true;
      };

      window = {
        position = "left";
        width = 30;
      };
    };
  };

  # Keybindings
  keymaps = [
    {
      mode = "n";
      key = "<leader>e";
      action = ":Neotree reveal<CR>";
      options = {
        desc = "NeoTree reveal";
        silent = true;
      };
    }
  ];
}
