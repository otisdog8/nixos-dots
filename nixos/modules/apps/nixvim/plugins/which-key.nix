# Which-key keybind helper
{ lib, ... }:
{
  plugins.which-key = {
    enable = true;
    lazyLoad.settings.event = "VimEnter";
    
    settings = {
      delay = 0;  # Show immediately
      
      icons = {
        breadcrumb = "»";
        group = "+";
        separator = "→";
        mappings = true;  # Use Nerd Font icons
        keys = {};  # Use default which-key Nerd Font icons
      };
      
      win = {
        border = "rounded";
      };
      
      spec = [
        # Search group
        { __unkeyed-1 = "<leader>s"; group = "[S]earch"; }
        
        # Toggle group
        { __unkeyed-1 = "<leader>t"; group = "[T]oggle"; }
        
        # LSP/Code actions (gr* prefix)
        { __unkeyed-1 = "gr"; group = "[G]oto/LSP"; }
        
        # Goto prefix (g)
        { __unkeyed-1 = "g"; group = "Goto"; }
        
        # Leader leader for buffers
        { __unkeyed-1 = "<leader><leader>"; group = "Buffers"; icon = "󰈙"; }
        
        # Search in buffer/files
        { __unkeyed-1 = "<leader>/"; group = "Search in Buffer"; }
      ];
      
      replace = {
        desc = [
          ["<space>" "SPACE"]
          ["<leader>" "SPACE"]
          ["<[cC][rR]>" "RETURN"]
          ["<[tT][aA][bB]>" "TAB"]
        ];
      };
    };
  };
}
