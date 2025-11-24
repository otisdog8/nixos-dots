# Network access feature
{ config, lib, ... }:

{
  imports = [ ../app-spec.nix ];

  config.app = {
    sandbox.network = lib.mkDefault true;
  };
}
