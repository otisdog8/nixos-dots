# Backend registry (Layer-2 lowerings).
#
# Each backend is a function
#   { appName, appCfg, cfg, config, lib, pkgs, inputs, storage } -> { package; systemConfig; }
# consuming the merged Layer-1 config (capabilities, storage, binds) and emitting
# concrete config: `package` goes on PATH / into finalPackage, `systemConfig` is
# merged into the host NixOS config (tmpfiles, persistence, units).
#
# app.defaultBackend (lib/app-spec.nix) selects one of these; "nixpak" is the
# default. A microVM backend is future work (not yet registered).
{
  none = import ./none.nix;
  nixpak = import ./nixpak.nix;
  systemd = import ./systemd.nix;
}
