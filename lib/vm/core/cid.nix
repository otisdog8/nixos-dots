# vsock CIDs. Every VM on a host needs a distinct one, and nothing checks for
# collisions at run time (the relay's port bind failing stops the second VM).
#
#   0-2               reserved by vsock (2 = the host)
#   [3, 3 + 2^28)     app VMs: 3 + the first 28 bits of sha256(<name>/<launch id>)
#   3 + 2^28          the agent VM (one per host)
{ lib, pkgs }:
let
  co = "${pkgs.coreutils}/bin";
in
{
  agentVm = 268435459; # 3 + 2^28: just past the app range

  # Shell: sets $cid for app VM `name`, launch id "$id".
  appShell = name: ''
    cid=$(( 3 + 16#$(printf '%s/%s' ${lib.escapeShellArg name} "$id" | ${co}/sha256sum | ${co}/cut -c1-7) ))
  '';
}
