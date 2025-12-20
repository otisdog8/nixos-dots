# AI coding assistant - Chat, inline edits, and agent workflows
{ config, lib, ... }:
{
  plugins.codecompanion = {
    enable = true;
    
    lazyLoad.settings.cmd = [
      "CodeCompanion"
      "CodeCompanionChat"
      "CodeCompanionActions"
      "CodeCompanionAdd"
    ];
    
    settings = {
      # Strategy configuration - use OpenCode ACP
      strategies = {
        chat = {
          adapter = "opencode";
        };
        inline = {
          adapter = "opencode";
        };
        cmd = {
          adapter = "opencode";
        };
      };
      
      # Display settings
      display = {
        action_palette = {
          provider = "snacks"; # Use snacks picker
        };
        chat = {
          show_settings = true;
          show_token_count = true;
        };
      };
      
      # Options
      opts = {
        send_code = true; # Include code context by default
        use_default_actions = true;
        use_default_prompts = true;
        log_level = "ERROR"; # Change to "DEBUG" for troubleshooting
      };
    };
  };
  
  # Keybindings
  keymaps = lib.optionals config.plugins.codecompanion.enable [
    # Toggle chat
    {
      mode = "n";
      key = "<leader>at";
      action = "<cmd>CodeCompanionChat Toggle<CR>";
      options.desc = "AI: Toggle chat";
    }
    
    # New chat
    {
      mode = "n";
      key = "<leader>ac";
      action = "<cmd>CodeCompanionChat<CR>";
      options.desc = "AI: New chat";
    }
    
    # Actions palette
    {
      mode = [ "n" "v" ];
      key = "<leader>aa";
      action = "<cmd>CodeCompanionActions<CR>";
      options.desc = "AI: Actions";
    }
    
    # Inline assistant
    {
      mode = "v";
      key = "<leader>ai";
      action = "<cmd>CodeCompanion<CR>";
      options.desc = "AI: Inline assistant";
    }
    
    # Quick prompts
    {
      mode = "n";
      key = "<leader>aq";
      action = "<cmd>CodeCompanion /commit<CR>";
      options.desc = "AI: Quick commit";
    }
    
    # Add to chat
    {
      mode = [ "n" "v" ];
      key = "<leader>ar";
      action = "<cmd>CodeCompanionAdd<CR>";
      options.desc = "AI: Add to chat";
    }
    
    # Change adapter
    {
      mode = "n";
      key = "<leader>am";
      action = "ga";
      options.desc = "AI: Change adapter";
    }
  ];
}
