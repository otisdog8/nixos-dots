# The sensitive cluster's server on carrack, a VM beside its main node
# (hosts/carrack-hv). Everything is in hosts/sensitive-common.nix.
{ ... }:
{
  imports = [ ../sensitive-common.nix ];
  modules.system.sensitiveGuest.machine = "carrack";
}
