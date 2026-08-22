# Add an explicit `<agent>-gpu` launcher. The ordinary agent command deliberately
# stays GPU-less; GPU device nodes, driver state, and APIs are exposed only when
# the user selects this more-privileged entry point.
{ config, ... }:
{
  imports = [ ../app-spec.nix ];
  config.app.gpuCommandName = "${config.app.packageName}-gpu";
}
