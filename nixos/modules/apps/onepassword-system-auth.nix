# "Unlock using system authentication" for 1Password in its sandbox VM, and the
# authorization prompt for a 1Password CLI connection (op-broker's `op`), both
# answered by the HOST user authenticating with their own polkit agent.
#
# How (docs/op-broker.md, "1Password's own prompt and system authentication"):
#   - the guest gets polkitd (D-Bus activated) and 1Password's polkit policy,
#     with the guest user as the policy owner 1Password looks for;
#   - a root guest service, sbx-polkit-agent (lib/vm/polkit-agent.py), is the
#     polkit agent for 1Password's processes (1Password checks its actions with
#     its OWN process as the subject);
#   - asked to authenticate, the agent sends {"op":"authenticate"} over the VM's
#     broker socket; the host sbx-broker runs pkcheck for a host action with a
#     fixed message, so the user's own agent (hyprpolkitagent) asks for their
#     password (or fingerprint, if PAM's polkit-1 does that) on the host;
#   - granted: the guest agent answers polkitd as root, completing 1Password's
#     check. One authentication per request (never "keep").
#
# Only for 1Password in its VM. In its container (nixpak), 1Password refuses
# polkit altogether: it checks that the system bus socket's directory, and the
# CLI's binary and its parent's, are owned by uid 0, and inside nixpak's
# unprivileged user namespace every host-root file shows up as uid 65534; it
# also passes its own (namespaced) pid to polkit. See the doc.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  cfg = config.modules.apps.onepassword-system-auth;
  has = options.modules.apps ? onepassword;
  onepw = if has then config.modules.apps.onepassword else null;
  inVm = onepw != null && onepw.enable && onepw.sandbox.mode == "vm";
  vmUser = config.modules.sandbox.vm.user;

  unlock = "com.1password.1Password.unlock";
  cli = "com.1password.1Password.authorizeCLI";
  hostUnlock = "org.otisroot.sandbox.onepassword.unlock";
  hostCli = "org.otisroot.sandbox.onepassword.authorize-cli";

  agent = import ../../../lib/vm/polkit-agent.nix pkgs;

  # 1Password's own policy (its .tpl), with the guest user as the owner: the app
  # only offers system authentication when its user is listed, and the owner
  # may pass details (authorizeCLI's message) with its checks.
  policy = pkgs.runCommand "1password-polkit-policy" { } ''
    mkdir -p $out/share/polkit-1/actions
    substitute ${pkgs._1password-gui}/share/1password/com.1password.1Password.policy.tpl \
      $out/share/polkit-1/actions/com.1password.1Password.policy \
      --replace-fail '${"$"}{POLICY_OWNERS}' 'unix-user:${vmUser}'
  '';
in
{
  options.modules.apps.onepassword-system-auth = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = inVm;
      defaultText = lib.literalMD "whether 1Password is enabled and runs in its VM";
      description = ''
        Let 1Password in its VM use "system authentication" (unlock, and
        authorizing 1Password CLI connections such as op-broker's), answered
        by you authenticating on the host through your polkit agent. VM only.
      '';
    };
  };

  config = lib.mkMerge [
    # Static attribute names (never derived from config), guarded by the app
    # module being imported at all, as in op-broker.nix.
    {
      modules.apps = lib.optionalAttrs has {
        onepassword.sandbox.vm.guestServices = lib.mkIf cfg.enable {
          polkit-agent = {
            argv = [
              (lib.getExe agent)
              "--user"
              vmUser
              "--exe"
              "1password"
              "--action"
              unlock
              "--action"
              cli
            ];
            root = true;
          };
        };
      };
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = inVm;
          message = ''
            modules.apps.onepassword-system-auth needs 1Password in its VM
            (modules.apps.onepassword.sandbox.mode = "vm"). In its container 1Password
            refuses polkit: nixpak's user namespace shows the system bus directory as
            owned by uid 65534, and its pid namespace hides the pids polkit needs.'';
        }
        {
          assertion = !inVm || !onepw.sandbox.vm.nested;
          message = "modules.apps.onepassword-system-auth: 1Password can't use system authentication nested in nixpak inside its VM (sandbox.vm.nested); the same user-namespace checks fail there.";
        }
        {
          # The host side is keyed on the VM's broker identity, vm-onepassword.
          assertion = !lib.any (g: lib.elem "onepassword" g.apps) (lib.attrValues config.modules.sandbox.groups);
          message = "modules.apps.onepassword-system-auth: 1Password must have its own VM (not a modules.sandbox.groups member).";
        }
        {
          assertion = config.modules.sandbox.broker.enable;
          message = "modules.apps.onepassword-system-auth asks the host through the sandbox broker (modules.sandbox.broker.enable).";
        }
      ];

      # One guest system for every VM: polkitd only starts when something asks
      # (D-Bus activation), and the policy is inert without 1Password.
      modules.sandbox.vm.guestModules = [
        {
          security.polkit.enable = true;
          environment.systemPackages = [ policy ];
        }
      ];

      modules.sandbox.broker.authActions = {
        ${hostUnlock} = {
          description = "Unlock 1Password (sandbox VM)";
          message = "1Password, in its sandbox VM, asks you to authenticate to unlock it.";
        };
        ${hostCli} = {
          description = "Authorize the 1Password CLI (sandbox VM)";
          message = "The 1Password CLI in 1Password's sandbox VM (op-broker, which fills logins in your browsers after asking you) asks you to authenticate to access your 1Password account.";
        };
      };
      # The VM's broker identity (lib/vm/instance.nix brokerName): vm-<instance>.
      modules.sandbox.broker.sandboxes.vm-onepassword.authenticate = {
        ${unlock} = hostUnlock;
        ${cli} = hostCli;
      };
    })
  ];
}
