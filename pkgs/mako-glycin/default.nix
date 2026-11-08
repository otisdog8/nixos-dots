# mako decoding its images (notification icons and images) with glycin, not
# gdk-pixbuf's own loaders: glycin runs each decoder in a bwrap sandbox of its
# own with a seccomp filter (libglycin, through glycin-loaders' programs), so a
# malicious image in a notification hits a sandboxed decoder, not mako.
#
# Scoped to mako: libglycin, glycin-loaders and a gdk-pixbuf built with them
# are used by this mako only, nothing else is rebuilt.
#
# Why our own glycin: gdk-pixbuf 2.44.8 (nixpkgs) needs glycin-2 >= 2.2.alpha.7
# for -Dglycin, and nixpkgs has libglycin 2.1.5. Drop the libglycin and
# glycin-loaders overrides here once nixpkgs ships glycin 2.2 (keep the
# gdk-pixbuf and mako parts, or drop those too once nixpkgs' gdk-pixbuf enables
# glycin itself).
#
# At run time (the wrapper below):
#   - This gdk-pixbuf has no module loaders (png, jpeg, gif, tiff, "others"
#     and xpm off; its loaders.cache is empty), so only the glycin loader built
#     into it decodes, for every format it handles. GDK_PIXBUF_MODULE_FILE is
#     unset for mako: a value from the session would point it at another
#     gdk-pixbuf's module loaders (librsvg's, webp, ...). Unset, not set to an
#     empty cache, so what mako runs (a notification action's command) doesn't
#     inherit a cache that hides its own loaders; it gets its gdk-pixbuf's
#     default. It does inherit the XDG_DATA_DIRS entry below, which only adds
#     glycin-loaders' data.
#   - XDG_DATA_DIRS gets glycin-loaders' share/ in front: libglycin finds the
#     loaders by share/glycin-loaders/2+/conf.d there. Prefixed, not set: mako
#     looks its icon themes up in the same variable.
#   - bwrap: libglycin runs the store's bubblewrap (nixpkgs' patchVendorHook
#     puts its path in). It needs unprivileged user namespaces, which the
#     desktops have (hardening.allowUserns: the app sandboxes use them too).
{
  lib,
  stdenv,
  fetchurl,
  rustPlatform,
  libglycin,
  glycin-loaders,
  gdk-pixbuf,
  mako,
  makeWrapper,
}:
let
  version = "2.2.5";
  src = fetchurl {
    url = "mirror://gnome/sources/glycin/${lib.versions.majorMinor version}/glycin-${version}.tar.xz";
    hash = "sha256-B2bDK4D82FgljP2Mu0J4PvyDXQ6SVv2/pr2tA0uwcX4=";
  };
  cargoDeps = rustPlatform.fetchCargoVendor {
    pname = "glycin";
    inherit version src;
    hash = "sha256-o0cCpcVk8JwmY9IoCkwSJqHE9l5Xnk5N6aUwc0HnAXc=";
  };
  # glycin 2.2 picks cargo's output directory itself (cargo_artifact_dir: the
  # target triple's subdirectory only for meson cross builds); nixpkgs builds
  # with CARGO_BUILD_TARGET set, so its output is always under the triple.
  # This replaces nixpkgs' 2.1 substitutions of libglycin/ and
  # glycin-loaders/meson.build, whose lines are gone.
  artifactDir = ''
    sed -i "s|^  cargo_artifact_dir = cargo_target_dir$|  cargo_artifact_dir = cargo_target_dir / '${stdenv.hostPlatform.rust.cargoShortTarget}'|" meson.build
    grep -q "^  cargo_artifact_dir = cargo_target_dir / '${stdenv.hostPlatform.rust.cargoShortTarget}'$" meson.build \
      || { echo "glycin meson.build: cargo_artifact_dir substitution did not apply" >&2; exit 1; }
  '';

  libglycin' = libglycin.overrideAttrs (_old: {
    inherit version src cargoDeps;
    postPatch = ''
      patchShebangs build-aux
    ''
    + artifactDir;
  });

  glycin-loaders' = (glycin-loaders.override { libglycin = libglycin'; }).overrideAttrs (_old: {
    inherit version src cargoDeps;
    postPatch = artifactDir;
  });

  # No tests: building them decodes test images with glycin, whose loaders
  # (and their bwrap sandbox) the build doesn't have; so no installedTests
  # output either.
  gdk-pixbuf' = gdk-pixbuf.overrideAttrs (old: {
    pname = "gdk-pixbuf-glycin";
    outputs = lib.remove "installedTests" old.outputs;
    mesonFlags =
      lib.filter (
        f:
        !lib.elem f [
          "-Dglycin=disabled"
          "-Dlegacy_xpm=enabled"
          "-Dothers=enabled"
        ]
      ) old.mesonFlags
      ++ [
        "-Dglycin=enabled"
        "-Dpng=disabled"
        "-Djpeg=disabled"
        "-Dgif=disabled"
        "-Dtiff=disabled"
        "-Dothers=disabled"
        "-Dlegacy_xpm=disabled"
        "-Dtests=false"
        "-Dinstalled_tests=false"
      ];
    # The mesonFlags edit above is matched by string: fail if it missed.
    postInstall = (old.postInstall or "") + ''
      for f in $out/lib/gdk-pixbuf-2.0/2.10.0/loaders/*; do
        [ -e "$f" ] || continue
        echo "gdk-pixbuf-glycin: module loader $f was built" >&2; exit 1
      done
    '';
    buildInputs = (old.buildInputs or [ ]) ++ [ libglycin' ];
  });

in
(mako.override { gdk-pixbuf = gdk-pixbuf'; }).overrideAttrs (old: {
  pname = "mako-glycin";
  nativeBuildInputs = old.nativeBuildInputs ++ [ makeWrapper ];
  postFixup = (old.postFixup or "") + ''
    wrapProgram $out/bin/mako \
      --unset GDK_PIXBUF_MODULE_FILE \
      --prefix XDG_DATA_DIRS : ${glycin-loaders'}/share
  '';
  passthru = (old.passthru or { }) // {
    libglycin = libglycin';
    glycin-loaders = glycin-loaders';
    gdk-pixbuf = gdk-pixbuf';
  };
})
