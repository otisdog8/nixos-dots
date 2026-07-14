# ccusage - analyse Claude Code + Codex token usage and costs from local data.
#
# ccusage only READS usage logs — Claude Code's (.claude/projects/**/*.jsonl) and
# Codex's (.codex/sessions, via `ccusage codex`). Those agents are themselves
# sandboxed now, so their data no longer lives in jrt's real ~/.claude / ~/.codex
# (those are empty) but in their per-app stashes. Both are nixpak apps with
# stashOwner = "user", so their persist leaves are 0700 jrt:users — readable by
# ccusage (also jrt). We bind those stash sources READ-ONLY into the spots ccusage
# expects (~/.claude, ~/.codex):
#   - claude-code → /persist/sandbox/claude-code/.claude  (projects/, history live here)
#   - codex       → /persist/sandbox/codex/.codex         (sessions/ live here)
# Only the persist tier is bound; the /large and /cache carves (security,
# file-history, caches) aren't usage logs, so ccusage never sees them.
#
# This is deliberately tighter than the agent sandboxes:
#   - READ-ONLY binds, so ccusage can never modify the agents' data or credentials.
#   - NO network. The static musl build embeds pricing data (litellm /
#     models.dev), so reports run fully offline. If a subcommand still tries to
#     fetch live pricing, pass --offline.
#   - No cwd / system-bin / ssl binds: the static binary needs nothing but
#     itself and the data directories.

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
            # Bind the agents' stash persist leaves to the home paths ccusage reads
            # from. Sources are the on-disk stashes (jrt no longer has real ~/.claude
            # / ~/.codex — the sandboxed agents keep their state here).
            bubblewrap.bind.ro = [
              [
                "/persist/sandbox/claude-code/.claude"
                (sloth.concat' sloth.homeDir "/.claude")
              ]
              [
                "/persist/sandbox/codex/.codex"
                (sloth.concat' sloth.homeDir "/.codex")
              ]
              # Tighter alternative (usage logs only, hides credentials/settings):
              # [ "/persist/sandbox/claude-code/.claude/projects" (sloth.concat' sloth.homeDir "/.claude/projects") ]
              # [ "/persist/sandbox/codex/.codex/sessions"        (sloth.concat' sloth.homeDir "/.codex/sessions") ]
            ];
          }
        )
      ];
    };
  }
)
