# The agents sandbox: every AI coding agent in one shared sandbox group
# (modules.sandbox.groups.agents), so they can work across several projects,
# run each other as subagents, and share credentials instead of each being
# provisioned separately.
#
# VM mode: ONE persistent VM (sandbox-vm-group-agents) with every agent's own
# storage (their logins included), the declared projects at their real paths,
# and the shared home paths. An agent started inside a project starts there.
# Container mode: likewise ONE persistent container (the user service
# sbx-group-agents, lib/backends/nixpak-group.nix) with every agent's storage,
# the projects and the shared paths.
# In both, an agent started in another folder of ~ gets that folder added to
# the running sandbox (until it stops; the broker's grant-path adds more on
# request) and starts there; started in ~ itself, it starts in the sandbox's
# home. A container agent started in a folder outside ~ it doesn't have runs in
# its own per-app sandbox instead (which also gets the projects and shared
# paths, and agent-peers' stashes to run the others).
#
# Less confined than one sandbox per agent by design: any agent here can read
# and change every declared project and every other agent's credentials.
{ config, lib, ... }:
let
  cfg = config.modules.sandbox.agents;
in
{
  options.modules.sandbox.agents = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the AI agents in the shared agents sandbox group.";
    };

    apps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "claude-code"
        "codex"
        "gemini-cli"
        "gsd"
        "opencode"
        "ccusage"
      ];
      description = "The agent apps in the group.";
    };

    projects = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "~/Documents/food-tracker"
        "~/Documents/nixos-dots"
      ];
      description = "Project directories every agent can read and write (absolute or ~/…).";
    };

    shareHome = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Home-relative paths (credentials, tool state) shared read-write with every agent. Missing ones are skipped.";
    };

    # Read-only: gh's config.yml names commands the HOST's gh runs (pager,
    # editor, browser, aliases), so an agent that could write it could run code
    # as the user outside any sandbox. Its token (hosts.yml) is still readable.
    # ~/.local/share/gh (extensions, also run by the host's gh) is not shared.
    shareHomeReadOnly = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ".config/gh" ];
      description = "Home-relative paths shared read-only with every agent. Missing ones are skipped.";
    };

    network = lib.mkOption {
      type = lib.types.enum [
        "default"
        "open"
        "internet"
        "allowlist"
      ];
      default = "open";
      description = ''
        The agents VM's network policy (lib/netpolicy.nix). "open" by default:
        agents talk to the tailnet (agent-auth, model servers) and local dev
        servers; "internet" keeps them off everything local.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    modules.sandbox.groups.agents = {
      inherit (cfg)
        apps
        projects
        shareHome
        shareHomeReadOnly
        ;
      persistent = true;
      network.mode = cfg.network;
    };
  };
}
