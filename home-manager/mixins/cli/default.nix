{
  config,
  inputs,
  lib,
  outputs,
  pkgs,
  stateVersion,
  username,
  ...
}:
let
  # starship's git: the real git with every filter driver the repo (or any
  # config) defines blanked, so the prompt never runs one. Status then compares
  # stat-dirty filtered files (git-crypt, LFS) raw; at worst the prompt shows
  # one as modified until git itself refreshes the index.
  starshipGit = pkgs.writeShellScriptBin "git" ''
    real=${pkgs.git}/bin/git
    globals=()
    while [ $# -gt 0 ]; do
      case $1 in
        -C | -c | --git-dir | --work-tree) globals+=("$1" "$2"); shift 2 ;;
        --git-dir=* | --work-tree=*) globals+=("$1"); shift ;;
        *) break ;;
      esac
    done
    blank=(-c core.fsmonitor=false -c core.hooksPath=/dev/null)
    while IFS= read -r -d "" key; do
      name=''${key#filter.}
      name=''${name%.*}
      # A name with "=" can't be passed to -c: give no status at all.
      case $name in *=*) exit 1 ;; esac
      blank+=(-c "filter.$name.clean=" -c "filter.$name.smudge=" -c "filter.$name.process=" -c "filter.$name.required=false")
    done < <("$real" "''${globals[@]}" config -z --name-only --get-regexp '^filter\..*\.(clean|smudge|process|required)$' 2>/dev/null)
    # Nor any submodule's own git: a nested repo is its own config (a sandbox
    # can add a gitlink and a sub/.git of its own), and only the command line
    # beats a .gitmodules "ignore = none".
    if [ "''${1-}" = status ]; then
      args=(status)
      shift
      for a in "$@"; do
        case $a in --ignore-submodules*) ;; *) args+=("$a") ;; esac
      done
      set -- "''${args[@]}" --ignore-submodules=all
    fi
    exec "$real" "''${globals[@]}" "''${blank[@]}" "$@"
  '';
  # starship with starshipGit first on its PATH. `starship init` prints the
  # path of the running binary into the shell's prompt hooks; rewrite it to
  # this wrapper, or the prompt would call the real binary and miss the PATH.
  starshipWrapped = pkgs.writeShellScriptBin "starship" ''
    real=${pkgs.starship}/bin/starship
    self=$(readlink -f "''${BASH_SOURCE[0]}")
    export PATH=${starshipGit}/bin:$PATH
    if [ "''${1-}" = init ]; then
      "$real" "$@" | ${pkgs.gnused}/bin/sed "s|$real|$self|g"
      exit "''${PIPESTATUS[0]}"
    fi
    exec "$real" "$@"
  '';
in
{
  programs = {
    git = {
      enable = true;
      signing.signByDefault = false;
      lfs.enable = true;
      signing.key = "~/.ssh/id_ed25519.pub";
      settings = {
        user = {
          email = "me@rooty.dev";
          name = "Jacob Root";
          signingkey = "~/.ssh/id_ed25519.pub";
        };
        # Sign all commits using ssh key
        gpg.format = "ssh";
        pull.rebase = true;
      };
    };
    ripgrep.enable = true;
    jq.enable = true;
    fastfetch.enable = true;
    eza.enable = true;
    bat.enable = true;
    btop.enable = true;
    ssh = {
      enable = true;
      enableDefaultConfig = false;
      settings."*".AddKeysToAgent = "yes";
    };
    zsh = {
      enable = true;
      history = {
        append = true;
        size = 100000;
        save = 100000;
        ignoreDups = true;
        ignoreSpace = true;
        expireDuplicatesFirst = true;
        share = true;
      };
      plugins = [
        {
          name = "vi-mode";
          src = pkgs.zsh-vi-mode;
          file = "share/zsh-vi-mode/zsh-vi-mode.plugin.zsh";
        }
      ];
      shellAliases = {
        cd = "z";
      };
      enableCompletion = true;
      #autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      initContent = builtins.readFile ../../../config/zsh;
    };
    starship = {
      enable = true;
      # The prompt runs `git status` in every repo you cd into, and status runs
      # the repo's filter drivers (clean/process) on stat-dirty files: code
      # execution from a repo's .git/config just by entering the directory. Its
      # git goes through starshipGit (above), which blanks every filter driver.
      package = starshipWrapped;
      settings = {
        command_timeout = 100;
        # gitoxide (the default) runs filter drivers too, and can't be told not
        # to; the git executable can (starshipGit).
        git_status.use_git_executable = true;
      };
    };
    zoxide.enable = true;
  };
  services = {
    ssh-agent.enable = true;
    mpris-proxy.enable = true;
  };

  # Host git never runs a repository's hooks or fsmonitor. Sandboxes can write
  # the projects they're given, and command-line/env config is the only kind a
  # repository's own config can't override (its .git/config is read-only in
  # the sandboxes, but a new repo or a .git/commondir it plants is not).
  home.sessionVariables = {
    GIT_CONFIG_COUNT = "2";
    GIT_CONFIG_KEY_0 = "core.hooksPath";
    GIT_CONFIG_VALUE_0 = "/dev/null";
    GIT_CONFIG_KEY_1 = "core.fsmonitor";
    GIT_CONFIG_VALUE_1 = "false";
  };

  home.file.".profile".text = ''
    export SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/ssh-agent
  '';

  home.activation.fixSshConfigPermissions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p "$HOME/.ssh"
    run chmod 700 "$HOME/.ssh"

    if [ -L "$HOME/.ssh/config" ]; then
      src="$(readlink -f "$HOME/.ssh/config")"
      if [ -f "$src" ]; then
        run rm -f "$HOME/.ssh/config"
        run install -m600 "$src" "$HOME/.ssh/config"
      fi
    fi
  '';
}
