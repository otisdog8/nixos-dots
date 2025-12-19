{
  config,
  inputs,
  lib,
  outputs,
  pkgs,
  stateVersion,
  username,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin isLinux;
in
{
  imports = [
    ./mixins/cli
    # Desktop config now managed by NixOS modules (modules/desktop/*)
  ];
  
  home = {
    username = username;
    homeDirectory = "/home/${username}";
    stateVersion = stateVersion;
  };
}
