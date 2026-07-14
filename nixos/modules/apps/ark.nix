# Ark — KDE archive manager, sandboxed to contain untrusted-archive parsing.
#
# Archive parsers (libarchive, unzip, p7zip, unrar, …) are a classic RCE surface,
# and Ark opens files that arrive via the already-sandboxed browsers / chat apps —
# the "downloaded a malicious .zip and opened it" vector. Contain it: nixpak
# same-uid (extracted files land as jrt, where the user expects them) with NO broad
# home access —
#   - ~/Downloads rw: the overwhelmingly common "extract a download" location.
#   - bind.lastArg: launched as `ark <path>` (file-manager "Open with", or CLI),
#     bind the archive's directory so "extract here" works.
#   - xdg-desktop portals: opening/extracting anywhere else goes through the
#     file-chooser portal, which grants access to exactly the picked file/folder.
# Deliberately NOT cwd.nix: a menu launch has $PWD=$HOME, which would bind the whole
# home rw and defeat the point.

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/features/gui.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "ark";
      package = pkgs.kdePackages.ark;
      packageName = "ark";

      defaultBackend = "nixpak";

      nixpakModules = [
        (
          { sloth, ... }:
          {
            bubblewrap.bind = {
              rw = [
                (sloth.concat' sloth.homeDir "/Downloads")
              ];
              # Bind the nearest existing ancestor of the archive path arg
              # (`ark ~/somewhere/foo.zip`) so extract-in-place works outside Downloads.
              lastArg = true;
            };
          }
        )
      ];
    };
  }
)
