# Plugin modules index
{ lib, ... }:
{
  imports = [
    ./blink-cmp.nix
    ./catppuccin.nix
    ./colorizer.nix
    ./conform.nix
    ./gitsigns.nix
    ./illuminate.nix
    ./indent-blankline.nix
    ./lint.nix
    ./lsp.nix
    ./lualine.nix
    ./mini.nix
    ./nvim-autopairs.nix
    ./rainbow-delimiters.nix
    ./snacks.nix
    ./todo-comments.nix
    ./treesitter.nix
    ./which-key.nix
  ];
}
