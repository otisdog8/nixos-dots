# Plugin modules index
{ lib, ... }:
{
  imports = [
    ./auto-save.nix
    ./auto-session.nix
    ./blink-cmp.nix
    ./catppuccin.nix
    ./codecompanion.nix
    ./colorizer.nix
    ./comment.nix
    ./conform.nix
    ./fidget.nix
    ./flash.nix
    ./gitsigns.nix
    ./illuminate.nix
    ./indent-blankline.nix
    ./leap.nix
    ./lint.nix
    ./lsp.nix
    ./lualine.nix
    ./mini.nix
    ./minuet.nix
    ./neo-tree.nix
    ./neogit.nix
    ./nvim-autopairs.nix
    ./nvim-surround.nix
    ./rainbow-delimiters.nix
    ./render-markdown.nix
    ./sleuth.nix
    ./snacks.nix
    ./todo-comments.nix
    ./treesitter.nix
    ./which-key.nix
  ];
}
