# The sensitive cluster's server on arquitens, a VM beside its main node
# (hosts/arquitens-hv). Everything is in hosts/sensitive-common.nix.
{ ... }:
{
  imports = [ ../sensitive-common.nix ];
  modules.system.sensitiveGuest.machine = "arquitens";
}
