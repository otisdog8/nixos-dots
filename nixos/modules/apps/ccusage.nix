# ccusage - analyse Claude Code token usage and costs from local data.
#
# ccusage only READS Claude Code's usage logs (~/.claude/projects/**/*.jsonl),
# so this sandbox is deliberately tighter than the agent sandboxes:
#   - ~/.claude is bound READ-ONLY, so ccusage can never modify your data,
#     settings, or credentials.
#   - NO network. The static musl build embeds pricing data (litellm /
#     models.dev), so reports run fully offline. If a subcommand still tries to
#     fetch live pricing, pass --offline.
#   - No cwd / system-bin / ssl binds: the static binary needs nothing but
#     itself and the data directory.
#
# To constrain further, swap the ~/.claude bind for just ~/.claude/projects
# (the only path ccusage reads for usage) to hide credentials/settings entirely
# - see the commented line below.

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    inputs,
    ...
  }:
  {
    imports = [
      ../../../lib/app-spec.nix
    ];

    config.app = {
      name = "ccusage";
      packageName = "ccusage";
      # Static musl build: self-contained, minimal closure, embedded pricing.
      package = inputs.ccusage.packages.${pkgs.stdenv.hostPlatform.system}.ccusage-static;

      nixpakModules = [
        (
          { sloth, ... }:
          {
            bubblewrap.bind.ro = [
              (sloth.concat' sloth.homeDir "/.claude")
              # Tighter alternative (usage logs only, hides credentials/settings):
              # (sloth.concat' sloth.homeDir "/.claude/projects")
            ];
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.ccusage.sandbox.enable = lib.mkDefault true;
        };
    };
  }
)
