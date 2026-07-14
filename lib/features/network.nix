# Network access feature (capability-based; lowered per backend).
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];
  config.app.capabilities.network = true;
}
