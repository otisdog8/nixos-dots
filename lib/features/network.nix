# Network access feature
{ config, lib, ... }:

{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ config, lib, ... }: {
      bubblewrap.network = lib.mkDefault true;
    })
  ];
}
