# Session management
{ lib, ... }:
{
  plugins.auto-session = {
    enable = true;

    settings = {
      # Use git branch name in session names
      git_use_branch_name = true;
      git_auto_restore_on_branch_change = false;

      # Keep default behavior for most settings
      enabled = true;
      auto_save = true;
      auto_restore = true;
      auto_create = true;
      auto_restore_last_session = false;

      # Suppress in common directories
      suppressed_dirs = [
        "~/"
        "~/Downloads"
        "/"
      ];

      log_level = "error";
      show_auto_restore_notif = false;
    };
  };

  # Keybindings
  keymaps = [
    {
      mode = "n";
      key = "<leader>wr";
      action = "<cmd>SessionSearch<CR>";
      options.desc = "Session search";
    }
    {
      mode = "n";
      key = "<leader>ws";
      action = "<cmd>SessionSave<CR>";
      options.desc = "Save session";
    }
    {
      mode = "n";
      key = "<leader>wa";
      action = "<cmd>SessionToggleAutoSave<CR>";
      options.desc = "Toggle session autosave";
    }
  ];
}
