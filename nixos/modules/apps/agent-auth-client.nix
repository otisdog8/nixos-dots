# agent-auth client tools — the `agent-auth` CLI and the `agent-auth-mcp`
# stdio server that Hermes instances (and Claude Code) use to request
# credentials from the broker (the sensitive cluster's broker.s.rooty.dev).
# Also `agent-auth-mcp-bridge <server>`: an MCP server from the broker's
# catalog as a local stdio server. The Rust flake's `client` package: those
# three programs and nothing else.
#
# AGENT_AUTH_URL is set system-wide so any client talks to the broker without
# per-instance config; what stays per-instance is the credential:
#   agents  → AGENT_AUTH_API_KEY (minted once via `agent-auth admin
#             agent-create <name>`, delivered in the instance's MCP env)
#   humans  → AGENT_AUTH_ADMIN_TOKEN for `agent-auth admin ...` (the
#             broker's ADMIN_TOKEN; never exported globally), with
#             AGENT_AUTH_URL=https://broker-admin.s.rooty.dev: the admin API
#             is on the admin door only (the agent door refuses /admin)
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.apps.agent-auth-client;
  client = inputs.agent-auth.packages.${pkgs.stdenv.hostPlatform.system}.client;
in
{
  options.modules.apps.agent-auth-client = {
    enable = lib.mkEnableOption "agent-auth client tools (CLI + MCP stdio server)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ client ];
    environment.variables.AGENT_AUTH_URL = "https://broker.s.rooty.dev";
  };
}
