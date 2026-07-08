# agent-auth client tools — the `agent-auth` CLI and the `agent-auth-mcp`
# stdio server that Hermes instances (and Claude Code) use to request
# credentials from the broker on recusant.
#
# Only the two client entrypoints are linked out of the broker's virtualenv:
# its bin/ also carries generic console scripts (fastapi, alembic, httpx,
# dotenv, ...) that would shadow real packages on PATH.
#
# AGENT_AUTH_URL is set system-wide so any client talks to the broker without
# per-instance config; what stays per-instance is the credential:
#   agents  → AGENT_AUTH_API_KEY (minted once via `agent-auth admin
#             agent-create <name>`, delivered in the instance's MCP env)
#   humans  → AGENT_AUTH_ADMIN_TOKEN for `agent-auth admin ...` (in the
#             sops env file on recusant; never exported globally)
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.apps.agent-auth-client;
  venv = inputs.agent-auth.packages.${pkgs.stdenv.hostPlatform.system}.default;
  client = pkgs.runCommand "agent-auth-client" { } ''
    mkdir -p $out/bin
    ln -s ${venv}/bin/agent-auth $out/bin/agent-auth
    ln -s ${venv}/bin/agent-auth-mcp $out/bin/agent-auth-mcp
  '';
in
{
  options.modules.apps.agent-auth-client = {
    enable = lib.mkEnableOption "agent-auth client tools (CLI + MCP stdio server)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ client ];
    environment.variables.AGENT_AUTH_URL = "https://agent-auth.recusant.rooty.dev";
  };
}
