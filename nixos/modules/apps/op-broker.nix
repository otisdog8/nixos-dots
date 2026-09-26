# op-broker: 1Password autofill for sandboxed browsers, one approved item at a
# time (design: docs/op-broker.md; code: pkgs/op-broker).
#
# The broker runs next to 1Password, never in a browser sandbox:
#   - 1Password in its container (the default): `op-broker.service`, as
#     app-onepassword with primary group onepassword-cli, bound to the lifetime of
#     sandbox-onepassword.service, reaching the desktop app's CLI socket in the
#     app's runtime dir.
#   - service-account auth: the same service as its own `op-broker` uid, with the
#     token from a root-only file; no desktop app involved.
#   - 1Password in its VM: the broker runs INSIDE that guest (uplink mode) and the
#     host runs only `op-broker-bridge.service`, a byte relay. The guest gets the
#     broker through sandbox.vm.guestServices and its uplink through
#     sandbox.vm.relays.
#
# Each browser in `browsers` gets its own socket, /run/op-broker/clients/<app>/sock.
# The socket a request arrives on IS the requester the dialog names. Container
# browsers get that directory bound at /run/sbx/op and the native-messaging
# manifest bound where the browser looks (wired here, through the app's
# sandbox.nixpakModules). VM browsers get the socket over their vsock relay and
# the manifest bound in the guest (sandbox.vm.relays / guestBinds).
#
# Installing the extension itself (policies / force-install) is left to the
# browser configuration; the ids and paths are exposed read-only under
# modules.apps.op-broker.extension.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  cfg = config.modules.apps.op-broker;
  apps = config.modules.apps;
  has = name: options.modules.apps ? ${name};

  opb = pkgs.callPackage ../../../pkgs/op-broker { };
  sbxPrompt = import ../../../lib/broker/prompt.nix pkgs;

  user = cfg.user;
  uid = toString config.users.users.${user}.uid;

  firefoxFamily = [
    "firefox"
    "zen-browser"
  ];
  chromiumFamily = [
    "chromium"
    "ungoogled-chromium"
    "brave"
  ];
  supported = firefoxFamily ++ chromiumFamily;
  defaultLabels = {
    firefox = "Firefox";
    zen-browser = "Zen Browser";
    chromium = "Chromium";
    ungoogled-chromium = "Ungoogled Chromium";
    brave = "Brave";
  };

  base = "/run/op-broker";
  clientDir = n: "${base}/clients/${n}";
  clientSock = n: "${clientDir n}/sock";
  uplinkDir = "${base}/uplink";
  # Inside every client sandbox (container bind or VM relay guest end).
  sandboxDir = "/run/sbx/op";

  onepw = if has "onepassword" then apps.onepassword else null;
  opInVm = onepw != null && onepw.sandbox.mode == "vm";
  desktop = cfg.auth == "desktop";
  # Who runs the broker on the host (container 1Password / service account).
  runAs = if desktop then "app-onepassword" else "op-broker";
  # Who owns the client socket directories: the broker, or the host bridge.
  socketOwner = if desktop && opInVm then "op-broker-bridge" else runAs;

  browserOn = b: has b && apps.${b}.enable && builtins.elem b cfg.browsers;
  browsers = lib.filter browserOn supported;
  inVm = b: apps.${b}.sandbox.mode == "vm";

  browserClient = b: {
    label = (cfg.labels.${b} or defaultLabels.${b}) + lib.optionalString (inVm b) " (VM)";
    # VM: the per-VM relay runs as the user in a system unit the user can't
    # move processes into. Container: the dedicated app uid, else the user.
    users =
      if inVm b then
        [ user ]
      else if apps.${b}.sandbox.dedicatedUser then
        [ "app-${b}" ]
      else
        [ user ];
    cgroup =
      if inVm b then "/system\\.slice/sandbox-vm-${lib.escapeRegex b}-relay(@[^/]*)?\\.service" else null;
  };
  clients = lib.genAttrs browsers browserClient // cfg.extraClients;

  brokerConfig = configDir: {
    clients = lib.mapAttrs (n: c: {
      inherit (c) label users cgroup;
      socket = clientSock n;
    }) clients;
    op = {
      path = lib.getExe' cfg.opPackage "op";
      inherit (cfg) account vaults;
      inherit configDir;
      timeout = 30;
      desktopIntegration = desktop;
    };
    prompt = {
      command = [ "${sbxPrompt}/bin/sbx-prompt" ];
      chooser = [ "${opb.broker}/bin/op-broker-choose" ];
      notice = lib.optional cfg.probe.notice "${opb.broker}/bin/op-broker-notice";
      inherit (cfg.prompt) timeout allowSession;
      queueWait = 5;
    };
    match = {
      inherit (cfg.match) mode allowHttp;
    };
    limits = cfg.limits;
    probe = {
      inherit (cfg.probe)
        distinct
        window
        interval
        block
        ;
    };
    audit.file = if cfg.auditFile then "/var/lib/op-broker/audit.jsonl" else null;
  };
  configFile = pkgs.writeText "op-broker.json" (
    builtins.toJSON (brokerConfig "/var/lib/op-broker/op")
  );
  # For the broker inside a 1Password VM: op keeps its default config dir.
  guestConfigFile = pkgs.writeText "op-broker-guest.json" (
    builtins.toJSON (brokerConfig null // { audit.file = null; })
  );
  bridgeConfigFile = pkgs.writeText "op-broker-bridge.json" (
    builtins.toJSON {
      clients = lib.mapAttrs (n: c: {
        inherit (c) users cgroup;
        socket = clientSock n;
      }) clients;
      uplink = {
        socket = "${uplinkDir}/sock";
        users = [ user ];
        cgroup = "/system\\.slice/sandbox-vm-onepassword-relay\\.service";
        wait = 5;
      };
      audit.file = null;
    }
  );

  nmName = opb.ids.nativeHost;
  # Container browsers: the client directory at /run/sbx/op (a directory, so a
  # broker restart's fresh socket is seen), and the native-messaging manifest
  # where the browser looks. Firefox-family reads ~/.mozilla/native-messaging-hosts
  # whatever MOZ_SYSTEM_DIR says; Chromium-family reads /etc/chromium (Chromium)
  # or /etc/opt/chrome (Chrome-lineage builds) — both bound, from the store.
  browserNixpak =
    b:
    { sloth, ... }:
    {
      bubblewrap.bind.rw = [
        [
          (clientDir b)
          sandboxDir
        ]
      ];
      bubblewrap.bind.ro =
        if builtins.elem b firefoxFamily then
          [
            [
              "${opb.nativeHost}/lib/mozilla/native-messaging-hosts/${nmName}.json"
              (sloth.concat' sloth.homeDir "/.mozilla/native-messaging-hosts/${nmName}.json")
            ]
          ]
        else
          [
            [
              "${opb.nativeHost}/etc/chromium/native-messaging-hosts"
              "/etc/chromium/native-messaging-hosts"
            ]
            [
              "${opb.nativeHost}/etc/opt/chrome/native-messaging-hosts"
              "/etc/opt/chrome/native-messaging-hosts"
            ]
          ];
    };

  browserGuestBinds =
    b:
    if builtins.elem b firefoxFamily then
      {
        "~/.mozilla/native-messaging-hosts/${nmName}.json" =
          "${opb.nativeHost}/lib/mozilla/native-messaging-hosts/${nmName}.json";
      }
    else
      {
        "/etc/chromium/native-messaging-hosts" = "${opb.nativeHost}/etc/chromium/native-messaging-hosts";
        "/etc/opt/chrome/native-messaging-hosts" = "${opb.nativeHost}/etc/opt/chrome/native-messaging-hosts";
      };

  # 1Password's own sandbox, desktop auth only: its runtime dir must be the real
  # host directory (where the broker, same uid, finds the CLI socket the app
  # opens there), and the app must be able to resolve the onepassword-cli group
  # it checks a connecting CLI's gid against. UNVERIFIED on hardware (see doc).
  onepasswordNixpak =
    { sloth, ... }:
    {
      bubblewrap.bind.rw = [ sloth.runtimeDir ];
      bubblewrap.bind.ro = [ "/etc/group" ];
    };

  hardening = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    ProtectSystem = "strict";
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    RestrictNamespaces = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ];
    UMask = "0077";
    LimitCORE = 0;
  };

  tmpfiles = [
    "d ${base} 0755 root root -"
    "d ${base}/clients 0755 root root -"
  ]
  ++ lib.concatLists (
    lib.mapAttrsToList (
      n: c:
      [ "d ${clientDir n} 0710 ${socketOwner} ${config.users.users.${socketOwner}.group} -" ]
      # Traverse only: enough to connect to (and bind-mount) the socket inside.
      ++ map (u: "a+ ${clientDir n} - - - - u:${toString u}:--x") c.users
    ) clients
  )
  ++ lib.optionals opInVm [
    "d ${uplinkDir} 0710 op-broker-bridge op-broker-bridge -"
    "a+ ${uplinkDir} - - - - u:${user}:--x"
  ];

  clientType = lib.types.submodule {
    options = {
      label = lib.mkOption {
        type = lib.types.str;
        description = "Name the dialog shows for this requester.";
      };
      users = lib.mkOption {
        type = lib.types.listOf (lib.types.either lib.types.str lib.types.int);
        description = "Users (names or uids) allowed to connect on this client's socket.";
      };
      cgroup = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Regex the connecting process's cgroup must fully match (null: no check).";
      };
    };
  };
in
{
  options.modules.apps.op-broker = {
    enable = lib.mkEnableOption "op-broker, per-item 1Password autofill for sandboxed browsers";

    browsers = lib.mkOption {
      type = lib.types.listOf (lib.types.enum supported);
      default = [ ];
      example = [
        "zen-browser"
        "ungoogled-chromium"
      ];
      description = ''
        Browser apps that get a broker socket (and, when they run in their
        container, the socket and native-messaging manifest bound into it).
        Browsers that aren't enabled are skipped.
      '';
    };

    labels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Dialog names per browser app, overriding the defaults.";
    };

    extraClients = lib.mkOption {
      type = lib.types.attrsOf clientType;
      default = { };
      description = "Further clients (name -> socket /run/op-broker/clients/<name>/sock).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "jrt";
      description = "The desktop user (VM relays and same-uid sandboxes run as this user).";
    };

    auth = lib.mkOption {
      type = lib.types.enum [
        "desktop"
        "service-account"
      ];
      default = "desktop";
      description = ''
        How `op` reaches the vault. "desktop": through the running 1Password app
        (CLI integration; the broker runs as app-onepassword while 1Password runs).
        "service-account": a service account token (only the vaults it was
        granted; never a Personal/Private vault), read from serviceAccountTokenFile.
      '';
    };

    serviceAccountTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/op-broker-token";
      description = "Root-only file with the service account token (passed with LoadCredential).";
    };

    opPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs._1password-cli;
      defaultText = lib.literalExpression "pkgs._1password-cli";
      description = "The 1Password CLI.";
    };

    account = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "`op --account` (sign-in address or account id), when several accounts are signed in.";
    };

    vaults = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Only offer items from these vaults (ids or names). Empty: every vault op can see.";
    };

    match = {
      mode = lib.mkOption {
        type = lib.types.enum [
          "exact"
          "subdomain"
        ];
        default = "subdomain";
        description = ''
          "exact": the page's host must equal the saved host. "subdomain": it may
          also be a subdomain of it (saved github.com fills on gist.github.com,
          never the reverse); such a match is marked SUBDOMAIN in the chooser
          and the approval dialog.
        '';
      };
      allowHttp = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Fill on plain-http pages (only with items saved for http).";
      };
    };

    prompt = {
      timeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Seconds before an unanswered dialog counts as a denial.";
      };
      allowSession = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Offer \"Allow until it stops\" (per requester, item and origin).";
      };
      waylandSocket = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = if desktop then "/run/user/${uid}/sandbox-onepassword-wayland" else null;
        defaultText = lib.literalMD ''
          desktop auth: the security-context socket the 1Password launcher holds
          for app-onepassword; service-account auth: null'';
        description = ''
          Wayland socket the broker's dialogs use, bound into the service by
          systemd. The broker's uid must be allowed to connect to it. With null
          there is no display, every dialog fails, and every request is denied.
        '';
      };
    };

    limits = lib.mkOption {
      type = lib.types.attrsOf lib.types.number;
      default = {
        burst = 5;
        perMinute = 10;
        perHour = 120;
        denyLimit = 3;
        denyCooldown = 300;
        listCacheTtl = 60;
        sessionIdle = 300;
        sessionMax = 28800;
      };
      description = ''
        Per requester: token bucket (burst, perMinute) and hourly cap on fill
        requests; cooldown (seconds) after denyLimit denials in a row; how long
        the item list (metadata only) is cached; how long a session grant
        outlives the browser's last connection, and its hard maximum.
      '';
    };

    probe = {
      notice = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Show a notice (with a "block it for an hour" button) when a browser
          looks like it is probing which sites have a saved login: `distinct`
          different sites with no saved login within `window` seconds, or
          hitting the rate limit. At most one notice per browser per `interval`
          seconds. Off: the events are still in the audit log.
        '';
      };
      distinct = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "Different no-login sites within `window` that count as probing.";
      };
      window = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = "Seconds of no-login requests considered together.";
      };
      interval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 600;
        description = "Minimum seconds between two notices about the same browser.";
      };
      block = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3600;
        description = "Seconds the notice's block button refuses that browser's requests for.";
      };
    };

    auditFile = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Also append the audit log (never secrets) to /var/lib/op-broker/audit.jsonl.";
    };

    # Read-only: what the browser configuration and the sandbox core need.
    extension = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        inherit (opb) ids;
        package = opb.extension;
        xpi = opb.extension.xpi;
        xpiUrl = "file://${opb.extension.xpi}";
        firefoxDir = opb.extension.firefoxDir;
        chromiumDir = opb.extension.chromiumDir;
        nativeHost = opb.nativeHost;
      };
      defaultText = lib.literalMD "the op-broker extension ids and store paths";
      description = "The extension (ids, XPI, unpacked dirs) and native host, for force-installing.";
    };

    relayServices = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      readOnly = true;
      default = lib.optionalAttrs cfg.enable (
        lib.mapAttrs (n: _: { op = clientSock n; }) (lib.filterAttrs (n: _: has n && inVm n) clients)
        // lib.optionalAttrs opInVm { onepassword.op-uplink = "${uplinkDir}/sock"; }
      );
      defaultText = lib.literalMD "per VM app: vsock relay service name -> host socket";
      description = ''
        Per VM app, the vsock relay services (wired through sandbox.vm.relays)
        it should get. Browser VMs: "op" -> their client socket, guest end at
        /run/sbx/op/sock. The 1Password VM: "op-uplink" -> the bridge, guest end
        at /run/sbx/op-uplink/sock.
      '';
    };

    guestBroker = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        package = opb.broker;
        configFile = guestConfigFile;
        command = [
          "${opb.broker}/bin/op-broker"
          "uplink"
          "--config"
          "${guestConfigFile}"
          "--path"
          "/run/sbx/op-uplink/sock"
        ];
      };
      defaultText = lib.literalMD "the uplink-mode broker for the 1Password VM guest";
      description = "What runs inside the 1Password VM (wired through sandbox.vm.guestServices).";
    };
  };

  config = lib.mkMerge [
    # Per-app sandbox wiring. The attribute names here are static (never derived
    # from config) so defining them can't recurse into modules.apps; each is
    # guarded by the app's module being imported at all.
    {
      modules.apps =
        lib.genAttrs (lib.filter has supported) (b: {
          sandbox.nixpakModules = lib.mkIf (cfg.enable && browserOn b && !(inVm b)) [ (browserNixpak b) ];
          # VM browsers: the client socket over the VM's vsock relay (guest end at
          # /run/sbx/op/sock, as in containers) and the manifest in the guest.
          sandbox.vm.relays = lib.mkIf (cfg.enable && browserOn b && inVm b) {
            op = {
              host = clientSock b;
              guest = "${sandboxDir}/sock";
            };
          };
          sandbox.vm.guestBinds = lib.mkIf (cfg.enable && browserOn b && inVm b) (browserGuestBinds b);
        })
        // lib.optionalAttrs (has "onepassword") {
          onepassword.sandbox.nixpakModules = lib.mkIf (cfg.enable && desktop && !opInVm) [
            onepasswordNixpak
          ];
          # 1Password in its VM: the broker runs in that guest (uplink mode, with
          # the group the app checks a CLI's gid against) and dials the host bridge.
          onepassword.sandbox.vm.relays = lib.mkIf (cfg.enable && desktop && opInVm) {
            op-uplink = {
              host = "${uplinkDir}/sock";
              guest = "/run/sbx/op-uplink/sock";
            };
          };
          onepassword.sandbox.vm.guestServices = lib.mkIf (cfg.enable && desktop && opInVm) {
            op-broker = {
              argv = cfg.guestBroker.command;
              group = "onepassword-cli";
            };
          };
        };
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = !desktop || onepw != null && onepw.enable;
          message = "modules.apps.op-broker: auth = \"desktop\" needs modules.apps.onepassword.enable.";
        }
        {
          assertion = desktop || cfg.serviceAccountTokenFile != null;
          message = "modules.apps.op-broker: auth = \"service-account\" needs serviceAccountTokenFile.";
        }
      ];

      warnings =
        lib.optional (cfg.prompt.waylandSocket == null && !(desktop && opInVm)) ''
          op-broker: modules.apps.op-broker.prompt.waylandSocket is null, so the broker
          can't show its dialogs and denies every request.'';

      users.groups.onepassword-cli = { };
      users.users.op-broker = lib.mkIf (!desktop) {
        isSystemUser = true;
        group = "op-broker";
      };
      users.groups.op-broker = lib.mkIf (!desktop) { };
      users.users.op-broker-bridge = lib.mkIf (desktop && opInVm) {
        isSystemUser = true;
        group = "op-broker-bridge";
      };
      users.groups.op-broker-bridge = lib.mkIf (desktop && opInVm) { };

      systemd.tmpfiles.rules = tmpfiles;

      systemd.services.op-broker = lib.mkIf (!(desktop && opInVm)) {
        description = "1Password per-item approval broker (op-broker)";
        # Desktop auth: only useful (and only able to reach op's socket) while
        # 1Password runs, and started with it.
        wantedBy = if desktop then [ "sandbox-onepassword.service" ] else [ "multi-user.target" ];
        bindsTo = lib.optional desktop "sandbox-onepassword.service";
        after = lib.optional desktop "sandbox-onepassword.service" ++ [ "systemd-tmpfiles-setup.service" ];
        environment = {
          HOME = "/var/lib/op-broker";
        }
        // lib.optionalAttrs desktop {
          # 1Password's runtime dir, where the app opens the CLI socket. Seen
          # live (read-only) under ProtectSystem=strict, never bound: the
          # 1Password launcher recreates the directory on every start.
          XDG_RUNTIME_DIR = "/run/app-onepassword";
        }
        // lib.optionalAttrs (cfg.prompt.waylandSocket != null) {
          # The dialogs' display (by default the security-context socket the
          # 1Password launcher holds and ACLs for app-onepassword), bound below.
          WAYLAND_DISPLAY = "/run/op-broker-ui/wayland-0";
        };
        serviceConfig = hardening // {
          Type = "notify";
          NotifyAccess = "main";
          ExecStart = lib.concatStringsSep " " (
            [
              "${opb.broker}/bin/op-broker"
              "serve"
              "--config"
              "${configFile}"
            ]
            ++ lib.optionals (!desktop) [
              "--token-file"
              "%d/op-token"
            ]
          );
          User = runAs;
          # The desktop app accepts a CLI whose gid is onepassword-cli; as the
          # primary group it needs no setgid wrapper (NoNewPrivileges stays on).
          Group = if desktop then "onepassword-cli" else "op-broker";
          StateDirectory = "op-broker";
          StateDirectoryMode = "0700";
          LoadCredential = lib.optional (!desktop) "op-token:${cfg.serviceAccountTokenFile}";
          Restart = "on-failure";
          RestartSec = 2;
          ProtectHome = true;
          ReadWritePaths = [ "${base}/clients" ];
          # The user's runtime dir is 0700 with no ACL for app uids (by design,
          # lib/backends/systemd.nix), so the socket is bound in by systemd (as
          # root), as the 1Password sandbox gets it. The unit restarts with
          # 1Password (bindsTo), so the bound inode is never stale.
          RuntimeDirectory = lib.mkIf (cfg.prompt.waylandSocket != null) "op-broker-ui";
          BindPaths = lib.mkIf (cfg.prompt.waylandSocket != null) [
            "-${cfg.prompt.waylandSocket}:/run/op-broker-ui/wayland-0"
          ];
          RestrictAddressFamilies = [
            "AF_UNIX"
          ]
          ++ lib.optionals (!desktop) [
            "AF_INET"
            "AF_INET6"
          ];
          IPAddressDeny = lib.mkIf desktop "any";
        };
      };

      systemd.services.op-broker-bridge = lib.mkIf (desktop && opInVm) {
        description = "op-broker host bridge to the broker in the 1Password VM";
        wantedBy = [ "sandbox-vm-onepassword.service" ];
        bindsTo = [ "sandbox-vm-onepassword.service" ];
        before = [ "sandbox-vm-onepassword.service" ];
        after = [ "systemd-tmpfiles-setup.service" ];
        serviceConfig = hardening // {
          Type = "notify";
          NotifyAccess = "main";
          ExecStart = "${opb.broker}/bin/op-broker bridge --config ${bridgeConfigFile}";
          User = "op-broker-bridge";
          Group = "op-broker-bridge";
          ProtectHome = true;
          ReadWritePaths = [ base ];
          RestrictAddressFamilies = [ "AF_UNIX" ];
          IPAddressDeny = "any";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };
    })
  ];
}
