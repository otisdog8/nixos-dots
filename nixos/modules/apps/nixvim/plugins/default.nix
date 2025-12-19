# Plugin modules index
{ lib, ... }:
{
  imports = [
    ./blink-cmp.nix
    ./catppuccin.nix
    ./lsp.nix
    ./lualine.nix
    ./mini.nix
    ./snacks.nix
    ./treesitter.nix
  ];
}
