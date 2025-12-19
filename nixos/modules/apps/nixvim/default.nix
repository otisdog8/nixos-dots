# Main nixvim configuration - imports all modules
{ lib, ... }:
{
  imports = [
    ./core.nix
    ./plugins
  ];
}
