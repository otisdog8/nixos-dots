# Enhanced UI for messages, cmdline, and notifications
{ lib, ... }:
{
  plugins.noice = {
    enable = true;
    lazyLoad.settings.event = "VimEnter";
    
    settings = {
      lsp = {
        # Let fidget handle LSP progress
        progress.enabled = false;
        
        override = {
          "vim.lsp.util.convert_input_to_markdown_lines" = true;
          "vim.lsp.util.stylize_markdown" = true;
          "cmp.entry.get_documentation" = true;
        };
        
        hover.enabled = true;
        signature.enabled = true;
      };
      
      # UI presets
      presets = {
        bottom_search = true;
        command_palette = true;
        long_message_to_split = true;
        inc_rename = false;
        lsp_doc_border = true;
      };
      
      # Route messages
      routes = [
        # Route less important messages to mini view
        {
          filter = {
            event = "msg_show";
            any = [
              { find = "%d+L, %d+B"; }
              { find = "; after #%d+"; }
              { find = "; before #%d+"; }
              { find = "written"; }
            ];
          };
          view = "mini";
        }
        
        # Skip LSP progress messages (fidget handles these)
        {
          filter = {
            event = "lsp";
            kind = "progress";
          };
          opts = { skip = true; };
        }
      ];
      
      # Command line settings
      cmdline = {
        enabled = true;
        view = "cmdline_popup";
        format = {
          cmdline = { icon = ">"; };
          search_down = { icon = "🔍⌄"; };
          search_up = { icon = "🔍⌃"; };
          filter = { icon = "$"; };
          lua = { icon = "☾"; };
          help = { icon = "?"; };
        };
      };
      
      # Message settings
      messages = {
        enabled = true;
        view = "notify";
        view_error = "notify";
        view_warn = "notify";
        view_history = "messages";
        view_search = "virtualtext";
      };
      
      # Popup menu
      popupmenu = {
        enabled = true;
        backend = "nui";
      };
      
      # Notification settings
      notify = {
        enabled = true;
        view = "notify";
      };
      
      # View defaults
      views = {
        cmdline_popup = {
          position = {
            row = 5;
            col = "50%";
          };
          size = {
            width = 60;
            height = "auto";
          };
        };
        popupmenu = {
          relative = "editor";
          position = {
            row = 8;
            col = "50%";
          };
          size = {
            width = 60;
            height = 10;
          };
          border = {
            style = "rounded";
            padding = [ 0 1 ];
          };
          win_options = {
            winhighlight = {
              Normal = "Normal";
              FloatBorder = "DiagnosticInfo";
            };
          };
        };
      };
    };
  };
  
  # Keymaps for noice features
  keymaps = [
    {
      mode = "n";
      key = "<leader>sn";
      action = "<cmd>Noice<CR>";
      options.desc = "Noice message history";
    }
    {
      mode = "n";
      key = "<leader>nl";
      action = "<cmd>Noice last<CR>";
      options.desc = "Noice last message";
    }
    {
      mode = "n";
      key = "<leader>nd";
      action = "<cmd>Noice dismiss<CR>";
      options.desc = "Dismiss all notifications";
    }
  ];
}
