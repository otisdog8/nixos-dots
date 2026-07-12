# Backend registry (Layer-2 lowerings).
#
# Each backend is a function
#   { appName, appCfg, cfg, config, lib, pkgs, inputs, storage } -> { package; systemConfig; }
# consuming the merged Layer-1 config (capabilities, storage, binds) and emitting
# concrete config: `package` goes on PATH / into finalPackage, `systemConfig` is
# merged into the host NixOS config (tmpfiles, persistence, units).
#
# "legacy" is not a backend here — it is the untouched pre-v2 code path in
# lib/apps.nix. systemd/vm land in later phases.
{
  none = import ./none.nix;
  nixpak = import ./nixpak.nix;
}
