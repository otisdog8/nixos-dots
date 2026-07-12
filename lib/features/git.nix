# Read-only access to the user's git config so sandboxed tools
# (commit signing, user identity, pull.rebase, etc.) inherit settings.
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];
  config.app.capabilities.gitConfig = true;
}
