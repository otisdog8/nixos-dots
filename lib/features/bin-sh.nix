# Provides /bin/sh inside the sandbox.
#
# A bwrap sandbox starts from an empty tmpfs root, so /bin does not exist and
# anything that execs an absolute `/bin/sh` (many build tools, language runtimes,
# git hooks, and agent shell tools that hardcode the path) fails with ENOENT.
# A bare `sh` still resolves via the package closure on PATH, but `/bin/sh`
# specifically does not.
#
# We bind a concrete bash ELF onto /bin/sh rather than the host's /bin/sh:
#   - bindEntireStore is on, so bash's libraries resolve from the read-only
#     /nix/store that is already mounted.
#   - Using a store path (not "/bin/sh") sidesteps two pitfalls that make a
#     naive `bind.ro = [ "/bin/sh" ]` quietly no-op: nixpak binds with
#     `--ro-bind-try`, which silently skips a missing/unresolved source, and the
#     host /bin/sh is itself a symlink into the store.
#   - bashInteractive matches the host's configured /bin/sh; invoked as `sh`
#     (basename of the bind target) bash runs in POSIX mode like the host.
{ pkgs, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    (_: {
      bubblewrap.bind.ro = [
        [
          "${pkgs.bashInteractive}/bin/bash"
          "/bin/sh"
        ]
      ];
    })
  ];
}
