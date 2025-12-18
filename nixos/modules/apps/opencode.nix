# Claude Code - AI-powered coding assistant

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
    imports = [
      ../../../lib/app-spec.nix
    ];

    config.app = {
      name = "opencode";
      packageName = "opencode";

      # Custom wrapped package with simple bwrap
      package = pkgs.writeShellScriptBin "opencode" ''
        exec ${pkgs.bubblewrap}/bin/bwrap \
          --ro-bind /nix/store /nix/store \
          --ro-bind /run/wrappers/bin /run/wrappers/bin \
          --ro-bind /etc/profiles/per-user/jrt/bin /etc/profiles/per-user/jrt/bin \
          --ro-bind /run/current-system/sw/bin /run/current-system/sw/bin \
          --ro-bind /etc/resolv.conf /etc/resolv.conf \
          --ro-bind /etc/hosts /etc/hosts \
          --ro-bind /etc/ssl/ /etc/ssl/ \
          --ro-bind /etc/static/ssl/ /etc/static/ssl/ \
          --dev /dev \
          --proc /proc \
          --tmpfs /tmp \
          --bind "$PWD" "$PWD" \
          --bind "$HOME/.opencode" "$HOME/.opencode" \
          --bind "$HOME/.config/opencode" "$HOME/.config/opencode" \
          --bind "$HOME/.local/share/opencode" "$HOME/.local/share/opencode" \
          --setenv PATH "$PATH" \
          --setenv HOME "$HOME" \
          --setenv PWD "$PWD" \
          --setenv USER "$USER" \
          --setenv TERM "$TERM" \
          --chdir "$PWD" \
          --share-net \
          --unshare-pid \
          ${pkgs.opencode}/bin/opencode "$@"
      '';

      # Persistence for Claude Code configuration
      persistence.user.persist = [
        ".cache/opencode"
        ".local/state/opencode"
        ".local/share/opencode"
        ".config/opencode"
        ".opencode"
      ];
    };
  }
)
