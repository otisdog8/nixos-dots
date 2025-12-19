# LSP configuration
{ lib, ... }:
{
  plugins.lspconfig.enable = true;

  lsp = {
    inlayHints.enable = true;
    servers.nixd.enable = true;
  };
}
