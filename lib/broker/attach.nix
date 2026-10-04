# sbx-attach (attach.py): the root side that binds a granted folder or the
# camera into a running container, and the client the broker's per-sandbox
# programs call. `forSandbox name` is the program sbx-broker runs for that
# sandbox's grant-path (`PROG PATH rw|ro`) and camera (`PROG attach`) ops.
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
