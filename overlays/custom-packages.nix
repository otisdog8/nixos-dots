{ inputs, ... }:
final: prev: {
  tetrio-desktop = final.callPackage ../pkgs/tetrio-desktop { };

  xdg-desktop-portal = prev.xdg-desktop-portal.overrideAttrs (oldAttrs: {
    src = inputs.xdg-desktop-portal-src;
  });
}