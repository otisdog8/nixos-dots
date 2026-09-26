# Launcher variants: extra entry points that run the SAME app under one specific
# sandbox implementation (`<bin>-container`, `<bin>-vm`), side by side with the
# app's primary command. Used by lib/apps.nix when modules.sandbox.variants is on.
{ lib, pkgs }:
let
  sed = "${pkgs.gnused}/bin/sed";

  # Exec=/TryExec= lines whose program is `bin` (bare or any absolute path to it)
  # → `newBin`. Desktop-action Exec= lines match too.
  execExpr = bin: newBin: "s#^((Try)?Exec=)([^ ]*/)?${lib.escapeRegex bin}( |$)#\\1${newBin}\\4#";
in
{
  inherit execExpr;

  # A package holding ONLY `bin/<bin>-<suffix>` (→ pkg's bin/<bin>) and renamed
  # copies of pkg's .desktop entries: "<Name> (<label>)", launching the suffixed
  # command. MimeType= and DBusActivatable= are dropped, so a variant never becomes
  # a default handler and is never D-Bus-activated as the primary app.
  mkVariant =
    {
      appName,
      pkg,
      bin,
      suffix,
      label,
    }:
    pkgs.runCommand "${appName}-${suffix}" { } ''
      mkdir -p $out/bin
      ln -s ${pkg}/bin/${bin} $out/bin/${bin}-${suffix}
      for f in ${pkg}/share/applications/*.desktop; do
        [ -e "$f" ] || continue
        mkdir -p $out/share/applications
        ${sed} -E \
          -e '${execExpr bin "${bin}-${suffix}"}' \
          -e 's#^(Name(\[[^]]*\])?=.*)$#\1 (${label})#' \
          -e '/^(DBusActivatable|MimeType)=/d' \
          "$f" > "$out/share/applications/$(basename "$f" .desktop)-${suffix}.desktop"
      done
    '';

  # pkg with every .desktop entry marked NoDisplay=true: still resolvable for MIME
  # associations and the default browser (which name the primary entry), just not
  # listed in launchers — the variants' entries are listed instead.
  hideDesktop =
    pkg:
    pkgs.symlinkJoin {
      name = "${pkg.name}-hidden";
      paths = [ pkg ];
      postBuild = ''
        for f in $out/share/applications/*.desktop; do
          [ -e "$f" ] || continue
          t="$(readlink -f "$f")"
          rm "$f"
          ${sed} -E -e '/^NoDisplay=/d' -e '/^\[Desktop Entry\]/a NoDisplay=true' "$t" > "$f"
        done
      '';
    };
}
