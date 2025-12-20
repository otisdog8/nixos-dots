# Markdown rendering for CodeCompanion chat UI
{ lib, ... }:
{
  plugins.render-markdown = {
    enable = true;
    
    settings = {
      file_types = [ "markdown" "codecompanion" ];
      
      # Heading rendering
      heading = {
        enabled = true;
        icons = [ "󰲡 " "󰲣 " "󰲥 " "󰲧 " "󰲩 " "󰲫 " ];
      };
      
      # Code block rendering
      code = {
        enabled = true;
        style = "normal";
        position = "left";
        width = "block";
      };
      
      # Bullet rendering
      bullet = {
        enabled = true;
        icons = [ "●" "○" "◆" "◇" ];
      };
      
      # Checkbox rendering
      checkbox = {
        unchecked = {
          icon = "󰄱 ";
        };
        checked = {
          icon = "󰱒 ";
        };
      };
    };
  };
}
