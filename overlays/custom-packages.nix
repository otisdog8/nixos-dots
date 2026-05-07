{ inputs, ... }:
final: prev: {
  zen-browser = inputs.zen-browser.packages.${final.stdenv.hostPlatform.system}.default;

  xdg-desktop-portal = prev.xdg-desktop-portal.overrideAttrs (oldAttrs: {
    src = inputs.xdg-desktop-portal-src;
  });

  # openldap's syncrepl integration test (test017) is timing-flaky and
  # regularly fails on local builders when the closure isn't already in
  # cache.nixos.org. Skip the check phase to keep wine/lutris (which pull
  # openldap transitively via samba) buildable from source.
  openldap = prev.openldap.overrideAttrs (oldAttrs: {
    doCheck = false;
  });
}
