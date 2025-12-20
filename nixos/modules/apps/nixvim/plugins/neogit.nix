# Git interface
{ lib, ... }:
{
  plugins.neogit = {
    enable = true;
    lazyLoad.settings.cmd = "Neogit";

    settings = {
      # Integration with snacks picker
      integrations = {
        telescope = null;
        diffview = false;
      };

      # Default settings
      disable_signs = false;
      disable_hint = false;
      disable_commit_confirmation = false;
      disable_builtin_notifications = false;
      disable_insert_on_commit = true;

      # Graph style
      graph_style = "unicode";

      # Signs
      signs = {
        hunk = [
          ""
          ""
        ];
        item = [
          ">"
          "v"
        ];
        section = [
          ">"
          "v"
        ];
      };
    };
  };

  # Keybindings
  keymaps = [
    {
      mode = "n";
      key = "<leader>gg";
      action = "<cmd>Neogit<CR>";
      options.desc = "Neogit";
    }
  ];
}
