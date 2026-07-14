# GPU acceleration feature (gaming, 3D, video) — capability-based.
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];
  config.app.capabilities.gpu = true;
}
