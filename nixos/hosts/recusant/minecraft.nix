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
  # Whitelists live in git-crypt-encrypted whitelist-secrets.nix (player roster
  # kept out of the plaintext repo). globalWhitelist → lobby + sdfs;
  # backendWhitelist → the modded backends.
  inherit (import ./whitelist-secrets.nix) globalWhitelist backendWhitelist;

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
    # All the Mods 9 — Forge 1.20.1 (Java 17). 1.20.1 forwarding rides the
    # Ambassador plugin on Velocity; no backend mod required.
    atm9 = {
      port = 25567;
      directory = "/mc/atm9-0.3.5";
      metricsMod = cpbForge_1_20_1;
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
      metricsMod = cpbNeoforge_1_21_1;
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "4G" "8G";
      modLoaderLauncher = true;
      pcf = pcfNeoforge_1_21_1; # NeoForge 1.21.1
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    # Better MC BMC5 — NeoForge 1.21.1 (Java 21). Stage the server pack manually
    # (incl. Proxy Compatible Forge for modern forwarding), like the other packs.
    bettermc = {
      port = 25574;
      directory = "/mc/bettermc";
      metricsMod = cpbNeoforge_1_21_1;
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "6G" "10G";
      modLoaderLauncher = true;
      pcf = pcfNeoforge_1_21_1; # NeoForge 1.21.1
      startupDelay = 180;
      autoShutdownDelay = 600;
    };

    evolution = {
      port = 25570;
      directory = "/mc/evolution";
      pcf = pcfNeoforge_1_21_1; # NeoForge (PCF 1.1.5 covers 1.20.1–26.1.2)
      # No cpburnz NeoForge build for 1.21.0; using the 1.21.1 jar (verify it loads).
      metricsMod = cpbNeoforge_1_21_1;
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "4G" "8G";
      modLoaderLauncher = true;
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    ob2 = {
      port = 25571;
      directory = "/mc/ob2";
      pcf = pcfNeoforge_1_21_1; # NeoForge (PCF 1.1.5 covers 1.20.1–26.1.2)
      metricsMod = cpbNeoforge_1_21_1;
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "3G" "6G";
      modLoaderLauncher = true;
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    sb4 = {
      port = 25572;
      directory = "/mc/sb4";
      pcf = pcfNeoforge_1_21_1; # NeoForge (PCF 1.1.5 covers 1.20.1–26.1.2)
      metricsMod = cpbNeoforge_1_21_1;
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "2G" "4G";
      modLoaderLauncher = true;
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    skies2 = {
      port = 25573;
      directory = "/mc/skies2";
      pcf = pcfNeoforge_1_21_1; # NeoForge (PCF 1.1.5 covers 1.20.1–26.1.2)
      metricsMod = cpbNeoforge_1_21_1;
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "4G" "8G";
      modLoaderLauncher = true;
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    # Fabric 1.20.1 (Java 17). Plain-jar launch (no unix_args.txt) + FabricProxy-
    # Lite for modern forwarding. Stage the pack into /mc/p2haustian.
    p2haustian = {
      port = 25575;
      directory = "/mc/p2haustian";
      metricsMod = cpbFabric_1_20_1;
      javaPackage = pkgs.jdk17;
      jvmOpts = modMem "2G" "4G";
      jar = "fabric-server-launcher.jar";
      modLoaderLauncher = false; # Fabric: plain jar, not unix_args.txt
      fabricProxy = fabricProxyLite_1_20_1; # Fabric 1.20.1
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    # Fabric 1.21.1 (Java 21). Plain-jar launch + FabricProxy-Lite.
    dungeonheroes = {
      port = 25576;
      directory = "/mc/dungeonheroes";
      metricsMod = cpbFabric_1_21_1;
      javaPackage = pkgs.jdk21;
      jvmOpts = modMem "2G" "4G";
      jar = "fabric-server-launcher.jar";
      modLoaderLauncher = false;
      fabricProxy = fabricProxyLite_1_21_1; # Fabric 1.21.1
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    # Forge 1.20.1 (Java 17). Like atm9: forwarding via Ambassador on the proxy,
    # so no backend mod.
    integratedmc = {
      port = 25577;
      directory = "/mc/integratedmc";
      metricsMod = cpbForge_1_20_1;
      javaPackage = pkgs.jdk17;
      jvmOpts = modMem "4G" "8G";
      modLoaderLauncher = true;
      startupDelay = 120;
      autoShutdownDelay = 600;
    };

    abyssalascent = {
      port = 25578;
      directory = "/mc/abyssalascent";
      metricsMod = cpbForge_1_20_1;
      javaPackage = pkgs.jdk17;
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
    # Paper survival (was a custom-module backend; now nix-managed + pinned).
    sdfs = {
      port = 25568;
      directory = "/mc/sdfs";
      startupDelay = 30;
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

  # server.properties forced on every custom-module backend so they behave as
  # proxy backends (version-agnostic; applied to all).
  proxyProps = {
    online-mode = false; # the proxy authenticates
    server-ip = "127.0.0.1"; # only reachable via Velocity
    enforce-secure-profile = false; # offline-mode backend behind the proxy
    white-list = backendWhitelist != { }; # enforce the restricted backend whitelist
  };

  # Forwarding mods, pinned per MC version. A backend selects its build with
  # `pcf = <jar>` (Forge/NeoForge → Proxy Compatible Forge) or
  # `fabricProxy = <jar>` (Fabric → FabricProxy-Lite); the matching config below
  # carries @FORWARDING_SECRET@ from the sops env file.
  pcfNeoforge_1_21_1 = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/vDyrHl8l/versions/9j2U3PgC/proxy-compatible-forge-1.1.5.jar";
    hash = "sha512-1o+HW/SPOqGLw3G7NfOD/Z+LlmbSRQBCXxyzUPiusewr2MYii8qw3ApnLlD1peNij5woc4bHKBR3DA3FDkAXyQ==";
  };
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

  fabricProxyLite_1_20_1 = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/8dI2tmqs/versions/XJmDAnj5/FabricProxy-Lite-2.6.0.jar";
    hash = "sha512-Nl0p667KVf/apNBmFBVZsA4xd0N7DZ+r7jmW/NvY4vuK5FwMYAyzV6BC7+dQyqK276r/pDn1cQy7BN7q6ZS33Q==";
  };
  fabricProxyLite_1_21_1 = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/8dI2tmqs/versions/KqB3UA0q/FabricProxy-Lite-2.10.1.jar";
    hash = "sha512-nAwdRLon7TSDu2B/lUQb6p+xxlviaqXcCvdDFn+3kzYjumEpNEc4sIQFau98tafbDbR3NI0HZy1cZ6LhIE6clA==";
  };
  fabricProxyLiteConfig = pkgs.writeText "FabricProxy-Lite.toml" ''
    hackOnlineMode = true
    hackEarlySend = false
    hackMessageChain = true
    disconnectMessage = "This server requires you to connect through the proxy."
    secret = "@FORWARDING_SECRET@"
  '';

  # ── Observability: Prometheus JMX agent on every JVM ──────────────────────
  # Universal JVM metrics (heap, GC, threads, CPU) + per-server up/down for the
  # whole network, regardless of loader. The agent binds all interfaces, but only
  # the tailnet reaches it: recusant opens just Velocity's 25565 publicly and
  # trusts tailscale0. Scrape <tailnet-ip>:<gamePort + 10000> from your external
  # Prometheus. Player/TPS metrics are a separate follow-up (per-loader
  # mods/plugins) — see minecraft-observability.md.
  jmxAgent = pkgs.fetchurl {
    url = "https://github.com/prometheus/jmx_exporter/releases/download/v1.6.0/jmx_prometheus_javaagent-1.6.0.jar";
    hash = "sha256-qVmD/ZboZdK835EcxQDnyCgIwnq5/SJr+WcytsPYxG4=";
  };
  jmxConfig = pkgs.writeText "jmx-exporter.yaml" ''
    lowercaseOutputName: true
    lowercaseOutputLabelNames: true
  '';
  # Metrics port for a server = its game port + 10000.
  jmxOpts = gamePort: "-javaagent:${jmxAgent}=${toString (gamePort + 10000)}:${jmxConfig}";
  # MC-specific exporters (sladkoff/cpburnz) bind game port + 20000.
  metricsPort2 = gamePort: gamePort + 20000;

  # sladkoff Prometheus exporter (Paper, for the lobby + sdfs). Host/port are set
  # via JVM system properties, so there's no config.yml to manage.
  sladkoffJar = pkgs.fetchurl {
    url = "https://github.com/sladkoff/minecraft-prometheus-exporter/releases/download/v3.1.2/minecraft-prometheus-exporter-3.1.2.jar";
    hash = "sha256-nfTBS/EQNMuHHSse23Hsc9CiW6mGD4uQ4JYA2D5I2js=";
  };
  sladkoffOpts =
    gamePort:
    "-Dminecraft.prometheus.exporter.host=0.0.0.0 -Dminecraft.prometheus.exporter.port=${toString (metricsPort2 gamePort)}";

  # cpburnz Prometheus Exporter mod (modded backends), pinned per loader+MC
  # version. A backend selects its build with `metricsMod = <jar>`.
  cpbForge_1_20_1 = pkgs.fetchurl {
    url = "https://github.com/cpburnz/minecraft-prometheus-exporter/releases/download/1.20.1-forge-1.2.1/Prometheus-Exporter-1.20.1-forge-1.2.1.jar";
    hash = "sha256-awn1nqhNT9lqdofK/eW7/jR5XQzrU1eocLMx50EuazQ=";
  };
  cpbNeoforge_1_21_1 = pkgs.fetchurl {
    url = "https://github.com/cpburnz/minecraft-prometheus-exporter/releases/download/1.21.1-neoforge-1.2.1/Prometheus-Exporter-1.21.1-neoforge-1.2.1.jar";
    hash = "sha256-OFPdv+s+nOBpyEc+t5n2FgwPtj8e+k6Z5VUz28Rc7/Y=";
  };
  cpbFabric_1_20_1 = pkgs.fetchurl {
    url = "https://github.com/cpburnz/minecraft-prometheus-exporter/releases/download/1.20.1-fabric-1.2.1/Prometheus-Exporter-1.20.1-fabric-1.2.1.jar";
    hash = "sha256-aw82PJw68RSATxMe2ezKtTzV8L7bricOtSHPkUKyCOs=";
  };
  cpbFabric_1_21_1 = pkgs.fetchurl {
    url = "https://github.com/cpburnz/minecraft-prometheus-exporter/releases/download/1.21.1-fabric-1.2.1/Prometheus-Exporter-1.21.1-fabric-1.2.1.jar";
    hash = "sha256-zM8aFV2BglFO7xlY0xhjThGE/XFWwXC2s3TvJX3z7hY=";
  };
  # The mod reads config/ (NeoForge) or world/serverconfig/ (Forge/Fabric); we
  # write both paths and let each loader pick its own.
  cpbConfig =
    port:
    pkgs.writeText "prometheus_exporter-server.toml" ''
      [collector]
      jvm = true
      mc = true
      mc_dimension_tick_errors = "LOG"
      mc_entities = true
      [web]
      listen_address = "0.0.0.0"
      listen_port = ${toString port}
    '';

  # mc-monitor — pings every server (loader-agnostic up/down + player counts) and
  # exports Prometheus on :9150. Static Go binary, runs as-is.
  mcMonitor = pkgs.stdenvNoCC.mkDerivation {
    pname = "mc-monitor";
    version = "0.16.7";
    src = pkgs.fetchurl {
      url = "https://github.com/itzg/mc-monitor/releases/download/0.16.7/mc-monitor_0.16.7_linux_amd64.tar.gz";
      hash = "sha256-dTVt93NHQD3EtLkx4KXBtGlrVaqUlFBdzchYAm3WPT8=";
    };
    sourceRoot = ".";
    dontConfigure = true;
    dontBuild = true;
    installPhase = "install -Dm755 mc-monitor $out/bin/mc-monitor";
  };
  monitorTargets = lib.concatStringsSep "," (
    map (p: "127.0.0.1:${toString p}") (
      [
        25565
        lobbyPort
      ]
      ++ lib.mapAttrsToList (_: b: b.port) (backends // nixBackends)
    )
  );

  # Velocity-specific proxy exporter (player connects/disconnects/kicks, per-server
  # distribution, online players + latency). JVM metrics are off here since the
  # JMX agent already covers them. Listens on the velocity port + 20000 (45565).
  bungeeExporterJar = pkgs.fetchurl {
    url = "https://github.com/weihao/bungeecord-prometheus-exporter/releases/download/3.2.7/bungeecord-prometheus-exporter-3.2.7.jar";
    hash = "sha256-+Nb1lmwhypGFod+skUnpBl6UYvGFKhbuc1FeNLhK2FQ=";
  };
  bungeeExporterConfig = pkgs.writeText "config.json" (
    builtins.toJSON {
      bstats = "false";
      host = "0.0.0.0";
      port = toString (metricsPort2 25565);
      prefix = "velocity_";
      jvm_gc = "false";
      jvm_memory = "false";
      jvm_threads = "false";
      player_connects = "true";
      player_disconnects = "true";
      player_kicks = "true";
      player_chats = "true";
      player_commands = "true";
      server_list_pings = "true";
      managed_servers = "true";
      installed_network_plugins = "true";
      online_player = "true";
      online_player_latency = "true";
      redis_player_connects = "false";
      redis_player_disconnects = "false";
      redis_online_player = "false";
      redis_bungee_online_proxies = "false";
    }
  );

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

  # mc-monitor: pings every server (proxy, lobby, all backends) and exports
  # loader-agnostic up/down + player counts on :9150 (tailnet-only via the
  # firewall). The on-demand backends read as down until AutoServer starts them.
  systemd.services.mc-monitor = {
    description = "mc-monitor Prometheus exporter";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${mcMonitor}/bin/mc-monitor export-for-prometheus -port 9150 -servers ${monitorTargets}";
      # Unprivileged + sandboxed: a transient user with no real account, and it's
      # a pure network client/server, so lock everything else down.
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = "30s";
      NoNewPrivileges = true;
      CapabilityBoundingSet = [ "" ];
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
    };
  };

  # ── CurseForge/Forge backends (custom module, on-demand) ──────────────────
  modules.apps.minecraft-server = {
    enable = true;
    operators = globalOperators;
    whitelist = backendWhitelist; # only godman180 on the modded backends for now
    environmentFile = config.sops.templates."minecraft.env".path; # forwarding secret
    servers = lib.mapAttrs (_: b: {
      enable = true;
      autoStart = false; # started on connect by AutoServer
      restart = "no"; # don't fight AutoServer's stop
      openFirewall = false; # reachable only via the proxy (localhost)
      inherit (b)
        directory
        port
        javaPackage
        modLoaderLauncher
        ;
      jvmOpts = "${b.jvmOpts} ${jmxOpts b.port}"; # + JMX metrics agent
      jar = b.jar or null;
      serverProperties = proxyProps;
      # Forwarding mod + config wired per loader; the backend carries the version-
      # specific jar in `pcf`/`fabricProxy` (the modpack jars are staged manually).
      #   pcf         → Proxy Compatible Forge (Forge/NeoForge)
      #   fabricProxy → FabricProxy-Lite (Fabric)
      # atm9 (Forge 1.20.1) uses Ambassador on the proxy, so no backend mod.
      symlinks =
        lib.optionalAttrs (b ? pcf) {
          "mods/zz-proxy-compatible-forge.jar" = b.pcf;
        }
        // lib.optionalAttrs (b ? fabricProxy) {
          "mods/zz-fabricproxy-lite.jar" = b.fabricProxy;
        }
        // lib.optionalAttrs (b ? metricsMod) {
          "mods/zz-prometheus-exporter.jar" = b.metricsMod; # cpburnz mod
        };
      files =
        lib.optionalAttrs (b ? pcf) {
          "config/proxy-compatible-forge.toml" = pcfConfig;
        }
        // lib.optionalAttrs (b ? fabricProxy) {
          "config/FabricProxy-Lite.toml" = fabricProxyLiteConfig;
        }
        // lib.optionalAttrs (b ? metricsMod) {
          # NeoForge reads config/, Forge/Fabric read world/serverconfig/ — write
          # both, each loader picks its own. Port = game port + 20000.
          "config/prometheus_exporter-server.toml" = cpbConfig (metricsPort2 b.port);
          "world/serverconfig/prometheus_exporter-server.toml" = cpbConfig (metricsPort2 b.port);
        };
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
      jvmOpts = "-Xmx1G -Xms512M -Dvelocity.max-known-packs=4096 ${jmxOpts 25565}";
      stopCommand = "end";
      path = [ pkgs.systemd ]; # AutoServer shells out to systemctl
      serverProperties = { }; # Velocity has none; suppress server.properties
      symlinks = {
        "plugins/autoserver.jar" = autoserverJar;
        "plugins/ambassador.jar" = ambassadorJar;
        "plugins/velocity-prometheus-exporter.jar" = bungeeExporterJar;
      };
      files = {
        "velocity.toml" = velocityTomlFile;
        "plugins/autoserver/config.toml" = autoserverTomlFile;
        "plugins/velocity-prometheus-exporter/config.json" = bungeeExporterConfig;
      };
    };

    servers.lobby = {
      enable = true;
      autoStart = true; # always-on `try` fallback
      # Pinned to the latest MC so the lobby never silently jumps versions on a
      # rebuild (keeps the paper-global.yml schema and the Via* plugins in sync).
      # ViaBackwards (5.9.1) covers every lower client version. Bump in lockstep
      # with the Via* pins.
      package = pkgs.paperServers.paper-26_1_2;
      # disableChannelLimit lets modded (Forge/NeoForge) clients register their
      # plugin channels without being kicked ("Invalid payload REGISTER").
      jvmOpts = "-Xmx2G -Xms1G -Dpaper.disableChannelLimit=true ${jmxOpts lobbyPort} ${sladkoffOpts lobbyPort}";
      # ViaVersion stack: accept clients from any modpack's MC version. Keep these
      # in sync with the lobby's Paper version if you pin it.
      symlinks = {
        "plugins/ViaVersion.jar" = viaVersionJar;
        "plugins/ViaBackwards.jar" = viaBackwardsJar;
        "plugins/ViaRewind.jar" = viaRewindJar;
        "plugins/prometheus-exporter.jar" = sladkoffJar; # sladkoff metrics
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

    # Paper survival (on-demand). Plugins in /mc/sdfs/plugins and the world are
    # unmanaged and persist; only server.properties/ops/whitelist are declarative.
    # Needs the same paper-global.yml velocity block as the lobby (one-time).
    servers.sdfs = {
      enable = true;
      autoStart = false;
      restart = "no";
      package = pkgs.paperServers.paper-1_21_11;
      # disableChannelLimit lets modded clients register their channels; the Via
      # stack lets any-version clients (e.g. 26.x) join this 1.21.11 server.
      jvmOpts = "${modMem "2G" "6G"} -Dpaper.disableChannelLimit=true ${jmxOpts 25568} ${sladkoffOpts 25568}";
      # Symlinked alongside the persistent /mc/sdfs/plugins jars (not replacing them).
      symlinks = {
        "plugins/ViaVersion.jar" = viaVersionJar;
        "plugins/ViaBackwards.jar" = viaBackwardsJar;
        "plugins/ViaRewind.jar" = viaRewindJar;
        "plugins/prometheus-exporter.jar" = sladkoffJar; # sladkoff metrics
      };
      operators = globalOperators;
      whitelist = globalWhitelist;
      serverProperties = {
        server-port = 25568;
        server-ip = "127.0.0.1";
        online-mode = false; # proxy authenticates
        enforce-secure-profile = false; # backend is offline-mode behind the proxy
        white-list = globalWhitelist != { };
        view-distance = 32; # the one non-default tuning from the old config
      };
    };
  };
}
