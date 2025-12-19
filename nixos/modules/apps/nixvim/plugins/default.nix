# Plugin modules index
{ lib, ... }:
{
  imports = [
    ./blink-cmp.nix
    ./catppuccin.nix
    ./conform.nix
    ./lint.nix
    ./lsp.nix
    ./lualine.nix
    ./mini.nix
    ./snacks.nix
    ./todo-comments.nix
    ./treesitter.nix
    ./which-key.nix
  ];
}
