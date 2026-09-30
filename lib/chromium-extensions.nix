# Chromium extensions from the Nix store, for browsers that can't install from
# the Chrome Web Store: ungoogled-chromium rewrites Google's domains, so its
# store installs can't work (and would contact Google on every start). Loaded
# unpacked (modules.apps.<browser>.browser.unpackedExtensions →
# --load-extension); updates are version bumps here.
{ pkgs }:
{
  # Its repository root is the unpacked extension (Vimium's "install from
  # source"); no build step.
  vimium = pkgs.fetchFromGitHub {
    owner = "philc";
    repo = "vimium";
    rev = "v2.4.2";
    hash = "sha256-i4JT2moQSVGzygC4BDAqkjioCAJiFCo5Bc5pmIAfovE=";
  };

  # uBlock Origin Lite's Chromium release (MV3; the full uBlock Origin is MV2,
  # which current Chromium no longer runs).
  ublock-origin-lite = pkgs.fetchzip {
    url = "https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.926.2202/uBOLite_2026.926.2202.chromium.zip";
    stripRoot = false;
    hash = "sha256-i/JMXBLXi2P5SQ9Fz0VsfmnVW44aAl2Sa9j/FtmtUKs=";
  };
}
