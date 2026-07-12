# Audio input and output (microphone + speakers) — capability-based.
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];
  config.app.capabilities.audio = true;
}
