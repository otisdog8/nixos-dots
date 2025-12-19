# Mini.nvim modules
{ lib, ... }:
{
  plugins.mini = {
    enable = true;
    modules = {
      icons = {
        style = "glyph";
      };
    };
    mockDevIcons = true;
  };
}
