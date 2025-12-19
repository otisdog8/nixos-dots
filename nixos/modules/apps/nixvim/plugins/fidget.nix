# LSP progress indicator
{ lib, ... }:
{
  plugins.fidget = {
    enable = true;
    lazyLoad.settings.event = "VimEnter";
    
    settings = {
      # LSP progress display
      progress = {
        poll_rate = 0;
        suppress_on_insert = true;
        ignore_done_already = false;
        ignore_empty_message = false;
        
        clear_on_detach = lib.nixvim.mkRaw ''
          function(client_id)
            local client = vim.lsp.get_client_by_id(client_id)
            return client and client.name or nil
          end
        '';
        
        notification_group = lib.nixvim.mkRaw ''
          function(msg) return msg.lsp_client.name end
        '';
        
        ignore = [ ];
        
        display = {
          render_limit = 16;
          done_ttl = 3;
          done_icon = "✔";
          done_style = "Constant";
          
          progress_ttl = 99999;
          progress_icon = {
            pattern = "dots";
            period = 1;
          };
          progress_style = "WarningMsg";
          group_style = "Title";
          icon_style = "Question";
          priority = 30;
          skip_history = true;
          
          overrides = {
            rust_analyzer = { name = "rust-analyzer"; };
          };
        };
      };
      
      # Notification system - DON'T override vim.notify (let noice handle it)
      notification = {
        poll_rate = 10;
        filter = "info";
        history_size = 128;
        override_vim_notify = false; # Let noice handle vim.notify
        
        window = {
          normal_hl = "Comment";
          winblend = 0;
          border = "none";
          zindex = 45;
          max_width = 0;
          max_height = 0;
          x_padding = 1;
          y_padding = 0;
          align = "bottom";
          relative = "editor";
        };
        
        view = {
          stack_upwards = true;
          icon_separator = " ";
          group_separator = "---";
          group_separator_hl = "Comment";
        };
      };
      
      # Logging
      logger = {
        level = "warn";
        float_precision = 0.01;
      };
    };
  };
}
