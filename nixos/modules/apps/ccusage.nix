# ccusage - analyse Claude Code + Codex token usage and costs from local data.
#
# ccusage only READS usage logs — Claude Code's (~/.claude/projects/**/*.jsonl) and
# Codex's (~/.codex/sessions, via `ccusage codex`) — so this sandbox is deliberately
# tighter than the agent sandboxes:
#   - ~/.claude and ~/.codex are bound READ-ONLY, so ccusage can never modify your
#     data, settings, or credentials.
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

      # v2 nixpak backend (replaces the legacy sandbox.enable path). Read-only tool:
      # no app.storage — it only binds ~/.claude READ-ONLY (below) and has no writable
      # state of its own.
      defaultBackend = "nixpak";

      nixpakModules = [
        (
          { sloth, ... }:
          {
            bubblewrap.bind.ro = [
              (sloth.concat' sloth.homeDir "/.claude")
              (sloth.concat' sloth.homeDir "/.codex")
              # Tighter alternative (usage logs only, hides credentials/settings):
              # (sloth.concat' sloth.homeDir "/.claude/projects")
              # (sloth.concat' sloth.homeDir "/.codex/sessions")
            ];
          }
        )
      ];
    };
  }
)
