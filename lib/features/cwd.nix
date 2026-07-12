# Bind the current working directory ($PWD) read-write — capability-based.
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];
  config.app.capabilities.cwd = true;
}
