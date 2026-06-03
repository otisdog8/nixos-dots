{ inputs, ... }:
final: prev: {
  zen-browser = inputs.zen-browser.packages.${final.stdenv.hostPlatform.system}.default;

  xdg-desktop-portal = prev.xdg-desktop-portal.overrideAttrs (oldAttrs: {
    src = inputs.xdg-desktop-portal-src;
  });

  nomachine-client = final.callPackage ../pkgs/nomachine-client { };
}
