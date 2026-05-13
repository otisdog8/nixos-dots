# Read-only access to the user's git config so sandboxed tools
# (commit signing, user identity, pull.rebase, etc.) inherit settings.
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    (
      { sloth, ... }:
      {
        bubblewrap.bind.ro = [
          (sloth.concat' sloth.homeDir "/.gitconfig")
          (sloth.concat' sloth.homeDir "/.config/git")
        ];
      }
    )
  ];
}
