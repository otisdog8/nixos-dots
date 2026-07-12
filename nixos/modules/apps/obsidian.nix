# Obsidian note-taking application — v2 systemd-stash backend.
#
# The profile (.config/obsidian) lives in a root-owned stash, hidden from
# unsandboxed jrt; its chromium caches go to the disposable /cache tier (sibling
# on-disk roots, so no same-tier nesting). The vault is host-visible (edited
# outside the sandbox too) and bound in via extraBinds — it's already persisted
# by the global ~/Documents impermanence entry.

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
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "obsidian";
      package = pkgs.obsidian;
      packageName = "obsidian";

      defaultBackend = "systemd";

      storage = [
        { path = ".config/obsidian"; tier = "persist"; } # profile (hidden stash)
        # Chromium caches → /cache tier (disposable, cross-tier so not nested).
        { path = ".config/obsidian/Cache"; tier = "cache"; }
        { path = ".config/obsidian/GPUCache"; tier = "cache"; }
        { path = ".config/obsidian/Code Cache"; tier = "cache"; }
        { path = ".config/obsidian/DawnCache"; tier = "cache"; }
        # Vault (notes + the executable .obsidian/plugins) → app-obsidian-owned
        # stash, so a compromised jrt can neither read the notes nor plant a
        # plugin that obsidian would run as app-obsidian.
        { path = "Documents/obsidian"; tier = "persist"; }
      ];

      customOptions = config: {
        vaultPath = lib.mkOption {
          type = lib.types.str;
          default = "Documents/obsidian";
          description = "Path to Obsidian vault directory (host-visible bind).";
        };
      };

      # Dedicated uid: profile AND vault are owned by app-obsidian, so a
      # compromised (non-root) jrt can't reach them (directly or via
      # /proc/<pid>/root). The vault is a stash entry above, no longer a shared
      # bind, so no extraBinds/ACLs are needed.
      customConfig =
        { config, lib, ... }:
        {
          modules.apps.obsidian.sandbox.dedicatedUser = true;
        };
    };
  }
)
