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
  services.hyprpaper = {
    enable = true;
    settings = {
      preload = "${inputs.self}/images/wallpaper.png";
      wallpaper = ", ${inputs.self}/images/wallpaper.png";
    };
  };
}
