# sbx-attach (attach.py): the root side that binds a granted folder or the
# camera into a running container (or a VM's grants share) and extends a
# running sandbox unit's IPAddressAllow= (grant-net), and the client the broker
# and its per-sandbox programs call. `forSandbox name` is the program sbx-broker
# runs for that sandbox's grant-path (`PROG PATH rw|ro`) and camera
# (`PROG attach`) ops; grant-net runs the client itself (`allow-ip SANDBOX
# UNIT ADDR`).
pkgs:
let
  python = "${pkgs.python3}/bin/python3 -IS";
  src = builtins.readFile ./attach.py;
in
rec {
  daemon = pkgs.writeScriptBin "sbx-attach" ("#!${python}\n" + src);
  client = pkgs.writeScriptBin "sbx-attach-client" ("#!${python}\n" + src);
  forSandbox =
    name:
    pkgs.writeShellScript "sbx-attach-${name}" ''
      exec ${client}/bin/sbx-attach-client ${pkgs.lib.escapeShellArg name} "$@"
    '';
}
