# Network access feature
{ config, lib, ... }:

{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ config, lib, ... }: {
      bubblewrap.network = true;
      etc.sslCertificates.enable = true;
    })
  ];
}
