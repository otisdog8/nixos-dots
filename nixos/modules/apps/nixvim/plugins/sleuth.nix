# Automatic indentation detection
{ lib, ... }:
{
  plugins.sleuth = {
    enable = true;
    
    settings = {
      # Enable heuristics by default
      heuristics = 1;
      
      # Keep filetype indent on (recommended)
      no_filetype_indent_on = 0;
    };
  };
}
