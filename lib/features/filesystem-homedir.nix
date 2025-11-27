# Grant access to home directory
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ lib, sloth, ... }: {
      bubblewrap.bind.rw = [
        sloth.homeDir
      ];
    })
  ];
}
