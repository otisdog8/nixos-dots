# The sensitive cluster's server on munificent, a VM beside its main node
# (hosts/munificent-hv). Everything is in hosts/sensitive-common.nix.
{ ... }:
{
  imports = [ ../sensitive-common.nix ];
  modules.system.sensitiveGuest.machine = "munificent";
}
