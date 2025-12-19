# Plugin modules index
{ lib, ... }:
{
  imports = [
    ./auto-save.nix
    ./auto-session.nix
    ./blink-cmp.nix
    ./catppuccin.nix
    ./colorizer.nix
    ./comment.nix
    ./conform.nix
    ./fidget.nix
    ./gitsigns.nix
    ./illuminate.nix
    ./indent-blankline.nix
    ./lint.nix
    ./lsp.nix
    ./lualine.nix
    ./mini.nix
    ./neo-tree.nix
    ./neogit.nix
    ./noice.nix
    ./nvim-autopairs.nix
    ./nvim-surround.nix
    ./rainbow-delimiters.nix
    ./snacks.nix
    ./todo-comments.nix
    ./treesitter.nix
    ./which-key.nix
  ];
}
