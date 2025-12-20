# Motion plugin for quick jumping
{ lib, ... }:
{
  plugins.leap = {
    enable = true;
    
    settings = {
      # Reduce visual noise in preview
      preview = lib.nixvim.mkRaw ''
        function(ch0, ch1, ch2)
          return not (
            ch1:match('%s')
            or (ch0:match('%a') and ch1:match('%a') and ch2:match('%a'))
          )
        end
      '';
      
      # Equivalence classes for brackets and quotes
      equivalence_classes = [
        " \t\r\n"
        "([{"
        ")]}"
        "'\"` "
      ];
    };
  };
  
  # Keybindings
  keymaps = [
    # Basic leap motions
    {
      mode = [ "n" "x" "o" ];
      key = "s";
      action = "<Plug>(leap)";
      options.desc = "Leap forward";
    }
    {
      mode = "n";
      key = "S";
      action = "<Plug>(leap-from-window)";
      options.desc = "Leap from window";
    }
    
    # Remote operations
    {
      mode = [ "n" "o" ];
      key = "gs";
      action = lib.nixvim.mkRaw ''
        function()
          require('leap.remote').action {
            input = vim.fn.mode(true):match('o') and "" or 'v'
          }
        end
      '';
      options.desc = "Leap remote action";
    }
  ];
  
  # Repeat keys configuration
  extraConfigLua = ''
    -- Use traversal keys to repeat previous motion
    require('leap.user').set_repeat_keys('<enter>', '<backspace>')
  '';
}
