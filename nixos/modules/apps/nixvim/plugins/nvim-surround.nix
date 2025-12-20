# Surround text objects
{ lib, ... }:
{
  plugins.nvim-surround = {
    enable = true;
    lazyLoad.settings.event = "VimEnter";

    settings = {
      # Keep default keymaps
      keymaps = {
        insert = "<C-g>s";
        insert_line = "<C-g>S";
        normal = "ys";
        normal_cur = "yss";
        normal_line = "yS";
        normal_cur_line = "ySS";
        visual = "S";
        visual_line = "gS";
        delete = "ds";
        change = "cs";
        change_line = "cS";
      };

      # Keep default aliases
      aliases = {
        a = ">";
        b = ")";
        B = "}";
        r = "]";
        q = [
          "\""
          "'"
          "`"
        ];
        s = [
          "}"
          "]"
          ")"
          ">"
          "\""
          "'"
          "`"
        ];
      };
    };
  };
}
