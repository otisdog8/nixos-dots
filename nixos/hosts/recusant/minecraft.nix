# Minecraft proxy network on recusant.
#
# Velocity (public, 25565) proxies a set of on-demand CurseForge/Forge modpack
# backends plus an always-on lobby. AutoServer (a Velocity plugin) starts a
# backend when a player connects and stops it when idle, via `systemctl` (a
# polkit rule from the custom module lets the `mc` user manage minecraft-* units).
#
# Frameworks:
#   - nix-minecraft  -> Velocity + lobby (and any future Modrinth/packwiz packs)
#   - custom module  -> CurseForge/Forge backends (mods staged manually)
# Both run as the single `mc` user with data under /mc.
#
# velocity.toml and the AutoServer config are GENERATED from the `backends` set
# below, so adding a modpack is a one-attr edit here + staging its files. See the
# runbook in /home/jrt/.claude/plans/look-at-the-minecraft-spicy-wind.md.
#
# ── One-time bootstrap on recusant (sops + manual config) ────────────────────
#   1. Forwarding secret (sops-nix, host age key):
#        nix shell nixpkgs#sops nixpkgs#ssh-to-age
#        ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub      # -> recusant age key
#        # add that key under creation_rules in .sops.yaml (repo root), then:
#        rm nixos/hosts/recusant/secrets/recusant.yaml
#        sops nixos/hosts/recusant/secrets/recusant.yaml
#        #   minecraft-forwarding-secret: <openssl rand -hex 24>
#   2. Velocity: first boot generates velocity.toml? No — Nix writes it. Nothing
#      to do; the secret comes from $VELOCITY_FORWARDING_SECRET (sops env file).
#   3. Lobby (Paper): first boot generates config/paper-global.yml; edit its
#      proxies.velocity block once: enabled=true, online-mode=true, secret=<same>.
#   4. Each backend: stage the CurseForge server pack into its directory, set
#      eula=true, online-mode=false, server-ip=127.0.0.1, and the forwarding mod
#      (Proxy Compatible Forge for 1.20.2+, or rely on Ambassador for 1.13-1.20.1).
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  tomlFormat = pkgs.formats.toml { };

  # ── Network-wide operators + whitelist (single source of truth) ───────────
  # Applied to every backend (custom module) AND the lobby (nix-minecraft). Use
  # online (Mojang) UUIDs — modern forwarding passes the real UUID to backends.
  # A bare UUID string means a full operator (level 4). Leave empty to disable.
  # The lobby is the network gate: with try = ["lobby"], a non-whitelisted player
  # is kicked there and never reaches a backend.
  globalOperators = {
    # bare UUID = level 4, bypassesPlayerLimit = false
    godman180 = "3da507e4-c6a7-4686-8073-1138136a017a";
  };
  globalWhitelist = {
    Walker_Zer0 = "5fe8d672-9f86-4346-8242-0cf1bf7c928a";
    MartianMetalhead = "8c261caf-ec81-4417-957d-4ad74e99bed3";
    Ziox_120_IGI = "a6fca0c2-a0ce-487d-b115-018dce84801e";
    rcwoshimao = "f8395b02-2f50-4dd8-b4b6-a859913200f0";
    godman180 = "3da507e4-c6a7-4686-8073-1138136a017a";
    BeExpectingMe = "16dfb4f6-07ed-4c3c-bc92-140234944cfd";
    thekingofrice = "08585c5a-c175-4b23-b296-45627f5d0f6b";
  };

  # Aikar's flags (the standard modded-server GC tuning; matches the atm10
  # user_jvm_args.txt). Memory is set per server below.
  aikarFlags = lib.concatStringsSep " " [
    "-XX:+UseG1GC"
    "-XX:+ParallelRefProcEnabled"
    "-XX:MaxGCPauseMillis=200"
    "-XX:+UnlockExperimentalVMOptions"
    "-XX:+DisableExplicitGC"
    "-XX:+AlwaysPreTouch"
    "-XX:G1NewSizePercent=30"
    "-XX:G1MaxNewSizePercent=40"
    "-XX:G1HeapRegionSize=8M"
    "-XX:G1ReservePercent=20"
    "-XX:G1HeapWastePercent=5"
    "-XX:G1MixedGCCountTarget=4"
    "-XX:InitiatingHeapOccupancyPercent=15"
    "-XX:G1MixedGCLiveThresholdPercent=90"
    "-XX:G1RSetUpdatingPauseTimePercent=5"
    "-XX:SurvivorRatio=32"
    "-XX:+PerfDisableSharedMem"
    "-XX:MaxTenuringThreshold=1"
    "-Dusing.aikars.flags=https://mcflags.emc.gs"
    "-Daikars.new.flags=true"
  ];
  mem = xms: xmx: "-Xms${xms} -Xmx${xmx}";
  modMem = xms: xmx: "${mem xms xmx} ${aikarFlags}";

  # ── Single source of truth for the modpack backends ───────────────────────
  # Each becomes: a custom-module service (minecraft-<name>, on-demand), a
  # Velocity [servers] entry, and an AutoServer [servers.<name>] block.
  #
  # CurseForge/Forge+NeoForge packs use modLoaderLauncher = true: the module
  # finds libraries/.../unix_args.txt at runtime, so we don't track each pack's
  # version here. Set javaPackage to match the pack's MC version (Java 21 for
  # ~1.20.5+/NeoForge 1.21, Java 17 for 1.17–1.20.4). Memory taken from each
  # pack's user_jvm_args.txt where it set one; sb4 set none, so a sane default.
  backends = {
    # Paper survival (formerly standalone). Needs its paper-global.yml velocity
    # block + online-mode=false to work behind the proxy.
    sdfs = {
      port = 25568;
      directory = "/mc/sdfs";
      javaPackage = pkgs.jdk21;
      jvmOpts = "${mem "2G" "6G"} ${aikarFlags}";
      jar = "paper.jar";
      modLoaderLauncher = false;
      startupDelay = 30;
      autoShutdownDelay = 600;
    };

    # All the Mods 9 — Forge 1.20.1 (Java 17). 1.20.1 forwarding rides the
    # Ambassador plugin on Velocity; no backend mod required.
    atm9 = {
      port = 25567;
      directory = "/mc/atm9-0.3.5";
      javaPackage = pkgs.jdk17;
      jvmOpts = modMem "6G" "10G";
      modLoaderLauncher = true;
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    # All the Mods 10 — NeoForge 1.21.1 (Java 21).
    atm10 = {
      port = 25569;
      directory = "/mc/atm10";
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "4G" "8G";
      modLoaderLauncher = true;
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    evolution = {
      port = 25570;
      directory = "/mc/evolution";
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "4G" "8G";
      modLoaderLauncher = true;
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    ob2 = {
      port = 25571;
      directory = "/mc/ob2";
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "3G" "6G";
      modLoaderLauncher = true;
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    sb4 = {
      port = 25572;
      directory = "/mc/sb4";
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "2G" "4G";
      modLoaderLauncher = true;
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    skies2 = {
      port = 25573;
      directory = "/mc/skies2";
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "4G" "8G";
      modLoaderLauncher = true;
      startupDelay = 120;
      autoShutdownDelay = 600;
    };
  };

  lobbyPort = 25566;

  # nix-minecraft-managed Modrinth backends (declarative .mrpack, on-demand). Same
  # model as the custom-module backends, but the unit is minecraft-server-<name>.
  nixBackends = {
    bettermc = {
      port = 25574;
      directory = "/mc/bettermc";
      startupDelay = 180;
      autoShutdownDelay = 600;
    };
    baplus = {
      port = 25575;
      directory = "/mc/baplus";
      startupDelay = 150;
      autoShutdownDelay = 600;
    };
  };

  # ── Generated Velocity + AutoServer config ────────────────────────────────
  # Velocity [servers] covers every backend (both frameworks) + the lobby.
  backendAddresses = lib.mapAttrs (_: b: "127.0.0.1:${toString b.port}") (backends // nixBackends);

  mkAutoserverEntry = unit: b: {
    workingDirectory = b.directory;
    start = "systemctl start ${unit}";
    stop = "systemctl stop ${unit}";
    remote = false;
    inherit (b) startupDelay autoShutdownDelay;
    shutdownDelay = 30;
  };

  velocityConfig = {
    config-version = "2.7";
    bind = "0.0.0.0:25565";
    motd = "<#5b9bd5>Recusant Network";
    show-max-players = 100;
    online-mode = true;
    force-key-authentication = true;
    player-info-forwarding-mode = "modern";
    # Secret is supplied via $VELOCITY_FORWARDING_SECRET (sops env file); this
    # file ref is the harmless fallback and is never populated by Nix.
    forwarding-secret-file = "forwarding.secret";
    announce-forge = true;
    kick-existing-players = false;
    enable-player-address-logging = true;
    servers = backendAddresses // {
      lobby = "127.0.0.1:${toString lobbyPort}";
      try = [ "lobby" ];
    };
    forced-hosts = { };
    advanced = {
      bungee-plugin-message-channel = true;
      failover-on-unexpected-server-disconnect = true;
    };
    query.enabled = false;
  };

  autoserverConfig = {
    checkForUpdates = false;
    messages = {
      prefix = "<gray>[<aqua>Network<gray>] ";
      starting = "<yellow>Starting that world, hang tight...";
      failed = "<red>That server failed to start. Try again in a moment.";
      notify = "<green>Ready! Connecting you now.";
    };
    servers =
      lib.mapAttrs (name: b: mkAutoserverEntry "minecraft-${name}" b) backends
      // lib.mapAttrs (name: b: mkAutoserverEntry "minecraft-server-${name}" b) nixBackends;
  };

  velocityTomlFile = tomlFormat.generate "velocity.toml" velocityConfig;
  autoserverTomlFile = tomlFormat.generate "autoserver-config.toml" autoserverConfig;

  # ── Velocity plugins, pinned from Modrinth ────────────────────────────────
  autoserverJar = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/7BmrOiXl/versions/uMUHzCdm/AutoServer-velocity-1.5.5.jar";
    hash = "sha512-pPZ1Fg00JY4EA5N8ZkYCjqrUlpWdJtabaTN7RQFBGZUY2LF0HO1TU6h5v7H1yMEgd6NWuLWwqEnyNuNxp3FmfA==";
  };
  ambassadorJar = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/cOj6YqJM/versions/YeQbhgna/Ambassador-Velocity-1.4.5-all.jar";
    hash = "sha512-IUCBtJhkTFxkDhrqI97/BGnRyELhFCqudCFDyHOKlxpImOrXLaFgXxwsICxPG+i88orMJ4fLzt4qhtZCrkj4HQ==";
  };

  # ── Lobby plugins: ViaVersion stack so a client on ANY modpack's MC version
  # can sit in the lobby. Velocity already accepts the wide protocol range at the
  # edge; the Via* plugins translate it on the (latest-Paper) lobby. Installed on
  # the lobby only, never the proxy (proxy-side Via causes keepalive/stutter).
  viaVersionJar = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/P1OZGk5p/versions/OGj9YIQN/ViaVersion-5.9.1.jar";
    hash = "sha512-e4nyd5xIc0L4p32ydYOpiGi7IBF6T6aKLgfaC7Ytpa70Rru8AXIKCpg6HqLpGmvSb8lHvv7hQP8eTiUev2As+A==";
  };
  viaBackwardsJar = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/NpvuJQoq/versions/W890fNPl/ViaBackwards-5.9.1.jar";
    hash = "sha512-PdqWj0OKGlqmDChW8Pp2fbZQGiexqOvR3HK6CYBEVu5gjL2CumahxymKCMnw450a464nzBa9+ssuMz6Tr/fsdQ==";
  };
  viaRewindJar = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/TbHIxhx5/versions/cOg14EE7/ViaRewind-4.1.1.jar";
    hash = "sha512-HB9Nt3XZ374oh3a9vS4LL0kQZDuQNGB9gT7lCdol/EXoTPsBg838MFYLJjLyTHXcxRpKm7Dej/KayeJL2J78lA==";
  };

  # ── Modrinth modpack backends (declarative via fetchModrinthModpack) ──────
  # fetchModrinthModpack is a fixed-output derivation: build once with
  # packHash = lib.fakeHash, then paste the sha256 Nix reports. Each pack's mods
  # are verified against the manifest's own hashes during the build.
  #
  # Forwarding mods (added to mods/ so these work behind Velocity's modern
  # forwarding): Proxy Compatible Forge for NeoForge, FabricProxy-Lite for Fabric.
  pcfNeoforgeJar = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/vDyrHl8l/versions/9j2U3PgC/proxy-compatible-forge-1.1.5.jar";
    hash = "sha512-1o+HW/SPOqGLw3G7NfOD/Z+LlmbSRQBCXxyzUPiusewr2MYii8qw3ApnLlD1peNij5woc4bHKBR3DA3FDkAXyQ==";
  };
  fabricProxyLiteJar = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/8dI2tmqs/versions/nR8AIdvx/FabricProxy-Lite-2.11.0.jar";
    hash = "sha512-wuHZJ59vGaVh+TS4RlQLKKAzWGtLQZucGqJ6xD/8j60s5g4hKhVAbl+jkH/17L5a96XtsYOp7mc3pB5GSuwTdQ==";
  };

  # Forwarding-mod configs. @FORWARDING_SECRET@ is substituted at start from the
  # sops env file (same mechanism as the lobby).
  pcfConfig = pkgs.writeText "proxy-compatible-forge.toml" ''
    [forwarding]
    enabled = true
    mode = "MODERN"
    secret = "@FORWARDING_SECRET@"
    approvedProxyHosts = []
    [crossStitch]
    enabled = true
    [debug]
    enabled = false
    [advanced]
    modernForwardingVersion = "NO_OVERRIDE"
  '';
  fabricProxyLiteConfig = pkgs.writeText "FabricProxy-Lite.toml" ''
    hackOnlineMode = true
    hackEarlySend = false
    hackMessageChain = true
    disconnectMessage = "This server requires you to connect through the proxy."
    secret = "@FORWARDING_SECRET@"
  '';

  # Better MC [NeoForge] BMC5 — NeoForge 21.1.176 / MC 1.21.1.
  bmc5Pack =
    (pkgs.fetchModrinthModpack {
      url = "https://cdn.modrinth.com/data/B37WQ89b/versions/Mo8ro6Ra/Better%20MC%20%5BNEOFORGE%5D%20BMC5%20v31.mrpack";
      packHash = lib.fakeHash; # build once → paste reported sha256
      pname = "better-mc-bmc5";
      version = "v31";
    }).addFiles
      { "mods/zz-proxy-compatible-forge.jar" = pcfNeoforgeJar; };

  # Better Adventures+ (BA+) — Fabric loader 0.18.4 / MC 1.21.11.
  baplusPack =
    (pkgs.fetchModrinthModpack {
      url = "https://cdn.modrinth.com/data/39X4pv9r/versions/zt2Xrekv/1.0.mrpack";
      packHash = lib.fakeHash; # build once → paste reported sha256
      pname = "better-adventures-plus";
      version = "1.0";
    }).addFiles
      { "mods/zz-fabricproxy-lite.jar" = fabricProxyLiteJar; };
in
{
  imports = [
    ../../modules/apps/minecraft-server.nix
    inputs.nix-minecraft.nixosModules.minecraft-servers
    inputs.sops-nix.nixosModules.sops
  ];

  # ── Secrets (sops-nix, recusant only) ─────────────────────────────────────
  sops = {
    defaultSopsFile = ./secrets/recusant.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    secrets."minecraft-forwarding-secret" = {
      owner = "mc";
      group = "mc";
      mode = "0440";
    };

    # Env file consumed by nix-minecraft (environmentFile). Keeps the secret out
    # of the Nix store. VELOCITY_* is read natively by Velocity; FORWARDING_SECRET
    # is available for @FORWARDING_SECRET@ substitution in any managed `files`.
    templates."minecraft.env" = {
      content = ''
        VELOCITY_FORWARDING_SECRET=${config.sops.placeholder."minecraft-forwarding-secret"}
        FORWARDING_SECRET=${config.sops.placeholder."minecraft-forwarding-secret"}
      '';
      owner = "mc";
      group = "mc";
      mode = "0440";
    };
  };

  # Console access to the tmux sockets and /mc files for the admin user.
  users.users.jrt.extraGroups = [ "mc" ];

  # ── CurseForge/Forge backends (custom module, on-demand) ──────────────────
  modules.apps.minecraft-server = {
    enable = true;
    operators = globalOperators;
    whitelist = globalWhitelist;
    servers = lib.mapAttrs (_: b: {
      enable = true;
      autoStart = false; # started on connect by AutoServer
      restart = "no"; # don't fight AutoServer's stop
      openFirewall = false; # reachable only via the proxy (localhost)
      inherit (b)
        directory
        port
        javaPackage
        jvmOpts
        modLoaderLauncher
        ;
      jar = b.jar or null;
    }) backends;
  };

  # ── Velocity + lobby (nix-minecraft), sharing the `mc` user ───────────────
  services.minecraft-servers = {
    enable = true;
    eula = true;
    user = "mc";
    group = "mc";
    dataDir = "/mc";
    managementSystem.tmux.enable = true;
    environmentFile = config.sops.templates."minecraft.env".path;

    servers.velocity = {
      enable = true;
      autoStart = true;
      openFirewall = true; # public entrypoint, port 25565
      package = pkgs.velocityServers.velocity;
      # Bumped known-packs cap for heavily-modded backends (default 64 can crash
      # the proxy during 1.20.5+ known-pack negotiation). Raise
      # -Dvelocity.max-plugin-message-payload-size too if a modded backend trips
      # a "Packet ... was too big" error on join.
      jvmOpts = "-Xmx1G -Xms512M -Dvelocity.max-known-packs=4096";
      stopCommand = "end";
      path = [ pkgs.systemd ]; # AutoServer shells out to systemctl
      serverProperties = { }; # Velocity has none; suppress server.properties
      symlinks = {
        "plugins/autoserver.jar" = autoserverJar;
        "plugins/ambassador.jar" = ambassadorJar;
      };
      files = {
        "velocity.toml" = velocityTomlFile;
        "plugins/autoserver/config.toml" = autoserverTomlFile;
      };
    };

    servers.lobby = {
      enable = true;
      autoStart = true; # always-on `try` fallback
      package = pkgs.paperServers.paper;
      # disableChannelLimit lets modded (Forge/NeoForge) clients register their
      # plugin channels without being kicked ("Invalid payload REGISTER").
      jvmOpts = "-Xmx2G -Xms1G -Dpaper.disableChannelLimit=true";
      # ViaVersion stack: accept clients from any modpack's MC version. Keep these
      # in sync with the lobby's Paper version if you pin it.
      symlinks = {
        "plugins/ViaVersion.jar" = viaVersionJar;
        "plugins/ViaBackwards.jar" = viaBackwardsJar;
        "plugins/ViaRewind.jar" = viaRewindJar;
      };
      # Same global ops/whitelist as the backends; nix-minecraft writes
      # ops.json/whitelist.json from these.
      operators = globalOperators;
      whitelist = globalWhitelist;
      serverProperties = {
        server-port = lobbyPort;
        server-ip = "127.0.0.1";
        online-mode = false; # proxy authenticates
        # Enforce the whitelist only when one is defined (an empty list +
        # white-list=true would lock everyone out). The lobby gates the network.
        white-list = globalWhitelist != { };
        difficulty = "peaceful";
        gamemode = "adventure";
        spawn-protection = 0;
        motd = "Recusant Lobby";
      };
    };

    # ── Modrinth modpack backends (on-demand, behind Velocity) ──────────────
    # mods/ is symlinked read-only (pack mods + the forwarding mod); config/ is a
    # writable copy reset to pack defaults each boot; the forwarding toml carries
    # the secret. world/ is unmanaged and persists.
    servers.bettermc = {
      enable = true;
      autoStart = false;
      restart = "no";
      package = pkgs.neoforgeServers.neoforge-1_21_1-21_1_176;
      jvmOpts = modMem "6G" "10G";
      operators = globalOperators;
      whitelist = globalWhitelist;
      symlinks."mods" = "${bmc5Pack}/mods";
      files = {
        "config" = "${bmc5Pack}/config";
        "defaultconfigs" = "${bmc5Pack}/defaultconfigs";
        "config/proxy-compatible-forge.toml" = pcfConfig;
      };
      serverProperties = {
        server-port = 25574;
        server-ip = "127.0.0.1";
        online-mode = false;
        white-list = globalWhitelist != { };
        motd = "Better MC BMC5";
      };
    };

    servers.baplus = {
      enable = true;
      autoStart = false;
      restart = "no";
      package = pkgs.fabricServers.fabric-1_21_11;
      jvmOpts = modMem "4G" "8G";
      operators = globalOperators;
      whitelist = globalWhitelist;
      symlinks."mods" = "${baplusPack}/mods";
      files = {
        "config" = "${baplusPack}/config";
        "config/FabricProxy-Lite.toml" = fabricProxyLiteConfig;
      };
      serverProperties = {
        server-port = 25575;
        server-ip = "127.0.0.1";
        online-mode = false;
        white-list = globalWhitelist != { };
        motd = "Better Adventures+";
      };
    };
  };
}
