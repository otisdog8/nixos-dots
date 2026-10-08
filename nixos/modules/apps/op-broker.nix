# op-broker: 1Password autofill for sandboxed browsers, one approved item at a
# time (design: docs/op-broker.md; code: pkgs/op-broker).
#
# On by default where 1Password runs in its VM (the one setup where the desktop
# app lets a CLI in; see the doc for why its container can't).
#
# The broker runs next to 1Password, never in a browser sandbox:
#   - 1Password in its container: `op-broker.service`, as app-onepassword with
#     primary group onepassword-cli, bound to the lifetime of
#     sandbox-onepassword.service, reaching the desktop app's CLI socket in the
#     app's runtime dir. (Wired, but the app refuses the connection: warned.)
#   - service-account auth: the same service as its own `op-broker` uid, with the
#     token from a root-only file; no desktop app involved.
#   - 1Password in its VM: the broker runs INSIDE that guest (uplink mode) and the
#     host runs only `op-broker-bridge.service`, a byte relay. The guest gets the
#     broker through sandbox.vm.guestServices and its uplink through
#     sandbox.vm.relays. 1Password's own authorization of the broker's CLI
#     session (and its system-authentication unlock) is asked of the host user
#     by onepassword-system-auth.nix.
#
# Each browser in `browsers` gets its own socket, /run/op-broker/clients/<app>/sock,
# and its VM /run/op-broker/clients/<app>-vm/sock (both, with sandbox variants).
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

  # The host broker (none with 1Password in its VM: it runs in that guest).
  hostBroker = !(desktop && opInVm);
  # Its display: a security-context socket of its own, held by
  # op-broker-display.service in the user's session, in a directory of the
  # user's that the broker's uid may only traverse, ACL'd by that same helper
  # for the broker's uid (wayland-security-context makes it 0600). The broker
  # connects to it as itself: nothing is bound in by systemd (as root) from a
  # directory the user controls, and it outlives sessions and 1Password.
  displayDir = "${base}/display";
  ownDisplay = hostBroker && cfg.prompt.waylandSocket == null;
  display = if ownDisplay then "${displayDir}/wayland-0" else cfg.prompt.waylandSocket;
  wlSecure = import ../../../lib/backends/wayland-security-context.nix pkgs;

  browserOn = b: has b && apps.${b}.enable && builtins.elem b cfg.browsers;
  browsers = lib.filter browserOn supported;
  inVm = b: apps.${b}.sandbox.mode == "vm";
  # With sandbox variants the launcher offers both "<App> (container)" and
  # "<App> (vm)", whatever the app's mode: each one gets its own client.
  variantsOn = config.modules.sandbox.variants.enable;
  containerWanted = b: !(inVm b) || variantsOn;
  vmWanted = b: inVm b || variantsOn;
  # The VM's client (and socket, /run/op-broker/clients/<app>-vm/sock).
  vmClient = b: "${b}-vm";

  # Who connects for a sandboxed app: its dedicated uid if it has one, else the
  # user. Container: the app itself. VM: the per-VM relay, a system unit the
  # user can't move processes into, which runs as that same uid
  # (lib/vm/instance.nix relayService).
  appUid = a: if apps.${a}.sandbox.dedicatedUser then "app-${a}" else user;
  # The 1Password VM's relay (uplink mode).
  uplinkUser = if onepw != null then appUid "onepassword" else user;

  browserClient = vm: b: {
    label = (cfg.labels.${b} or defaultLabels.${b}) + lib.optionalString vm " (VM)";
    users = [ (appUid b) ];
    cgroup =
      if vm then "/system\\.slice/sandbox-vm-${lib.escapeRegex b}-relay(@[^/]*)?\\.service" else null;
  };
  clients =
    lib.genAttrs (lib.filter containerWanted browsers) (browserClient false)
    // lib.listToAttrs (
      map (b: lib.nameValuePair (vmClient b) (browserClient true b)) (lib.filter vmWanted browsers)
    )
    // cfg.extraClients;

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
  # For the broker inside a 1Password VM: op keeps its default config dir, and
  # runs from root-owned copies on the guest's tmpfs (guestBrokerStart): the
  # desktop app accepts a CLI only when its binary and its parent's are owned
  # by root and not on FUSE, and the guest's virtio-fs /nix/store is FUSE with
  # the host's root-owned files showing as nobody's.
  guestOpDir = "/run/sbx/op-bin";
  # How long one `op` run may take in the guest. The first run (and any run
  # while 1Password is locked) waits for 1Password's own authorization: the
  # host's polkit dialog, answered by you typing a password. Killing op before
  # that is answered cancels the host dialog under your fingers (and counts as
  # a failed authentication towards the broker's 3-strikes pause), so this is
  # well above the host-side serve mode's 30 s. The launcher (`timeout`) stops
  # op itself; the broker's own limit is later, so it never kills only the
  # launcher and leaves op running.
  guestOpTimeout = 120;
  guestConfigFile = pkgs.writeText "op-broker-guest.json" (
    builtins.toJSON (
      lib.recursiveUpdate (brokerConfig null) {
        audit.file = null;
        op = {
          path = "/run/wrappers/bin/op";
          timeout = guestOpTimeout + 10;
          # timeout forks op and waits, so op's parent is this root-owned copy
          # (the broker's own interpreter is a store path).
          launcher = [
            "${guestOpDir}/timeout"
            "--kill-after=5"
            (toString guestOpTimeout)
          ];
        };
      }
    )
  );
  # The broker's dialogs (zenity, GTK 4) in the guest. The guest services get
  # only XDG_RUNTIME_DIR/WAYLAND_DISPLAY/the session bus, none of the GUI
  # environment the app's launcher passes: the generic guest system has no
  # fonts at all (fonts.packages is empty; the app gets the host's
  # FONTCONFIG_FILE), and with the cross-domain display there is no GPU
  # behind the guest's virtio-gpu, so GTK's default Vulkan/GL renderers probe
  # drivers that can't work. Dialogs need neither: the host's font
  # configuration (store paths plus their prebuilt cache, as the app gets it)
  # and GTK's software renderer.
  guestDialogEnv = {
    GSK_RENDERER = "cairo";
    LIBGL_ALWAYS_SOFTWARE = "1";
  }
  // lib.optionalAttrs config.fonts.fontconfig.enable {
    FONTCONFIG_FILE = "${lib.removeSuffix "/" "${config.environment.etc.fonts.source}"}/fonts.conf";
  };
  # The guest service (as root): copy op and timeout to a root-owned tmpfs
  # directory, then become the user (own groups: op gets onepassword-cli from
  # its setgid wrapper, /run/wrappers/bin/op) and run the broker.
  guestBrokerStart = pkgs.writeShellScript "op-broker-guest-start" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.shadow
        pkgs.glibc.getent
        pkgs.util-linux
      ]
    }
    d=${guestOpDir}
    umask 022
    # Declared in the guest system (guestModules below), so it exists before
    # 1Password starts; this is only the fallback for an older guest.
    getent group onepassword-cli >/dev/null || groupadd -g ${toString config.ids.gids.onepassword-cli} onepassword-cli
    install -d -m 0755 -o root -g root "$d"
    install -m 0755 -o root -g root "$(readlink -f ${lib.getExe' cfg.opPackage "op"})" "$d/op.new"
    mv -f "$d/op.new" "$d/op"
    install -m 0755 -o root -g root "$(readlink -f ${pkgs.coreutils}/bin/timeout)" "$d/timeout.new"
    mv -f "$d/timeout.new" "$d/timeout"
    home="$(getent passwd ${user} | cut -d: -f6)"
    exec setpriv --reuid=${user} --regid="$(id -g ${user})" --init-groups \
      env HOME="$home" USER=${user} LOGNAME=${user} ${
        lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${lib.escapeShellArg v}") guestDialogEnv)
      } \
      ${opb.broker}/bin/op-broker uplink --config ${guestConfigFile} --path /run/sbx/op-uplink/sock
  '';
  bridgeConfigFile = pkgs.writeText "op-broker-bridge.json" (
    builtins.toJSON {
      clients = lib.mapAttrs (n: c: {
        inherit (c) users cgroup;
        socket = clientSock n;
      }) clients;
      uplink = {
        socket = "${uplinkDir}/sock";
        users = [ uplinkUser ];
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
    "a+ ${uplinkDir} - - - - u:${uplinkUser}:--x"
  ]
  ++ lib.optionals ownDisplay [
    "d ${displayDir} 0700 ${user} ${config.users.users.${user}.group} -"
    "a+ ${displayDir} - - - - u:${runAs}:--x"
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
    enable = lib.mkOption {
      type = lib.types.bool;
      default = onepw != null && onepw.enable && opInVm;
      defaultText = lib.literalMD ''
        whether 1Password is enabled and runs in its VM (the one place the
        desktop app lets a CLI in: see docs/op-broker.md on the container)'';
      description = "Whether to enable op-broker, per-item 1Password autofill for sandboxed browsers.";
    };

    browsers = lib.mkOption {
      type = lib.types.listOf (lib.types.enum supported);
      default = supported;
      defaultText = lib.literalExpression (builtins.toJSON supported);
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
        default = null;
        description = ''
          A Wayland socket for the host broker's dialogs, which the broker
          connects to as its own uid (it must be able to reach and connect to
          it; nothing is bound in). null (the default): a security-context
          socket of the broker's own, held by op-broker-display.service in your
          session under /run/op-broker/display. (1Password in its VM: the
          broker runs in that guest and uses the VM's display.)
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
        lib.genAttrs (lib.filter vmWanted browsers) (b: { op = clientSock (vmClient b); })
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
        # Run as the guest's root: it drops to the user itself (see guestBrokerStart).
        command = [ "${guestBrokerStart}" ];
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
          sandbox.nixpakModules = lib.mkIf (cfg.enable && browserOn b && containerWanted b) [ (browserNixpak b) ];
          # VM browsers: the client socket over the VM's vsock relay (guest end at
          # /run/sbx/op/sock, as in containers) and the manifest in the guest.
          sandbox.vm.relays = lib.mkIf (cfg.enable && browserOn b && vmWanted b) {
            op = {
              host = clientSock (vmClient b);
              guest = "${sandboxDir}/sock";
            };
          };
          sandbox.vm.guestBinds = lib.mkIf (cfg.enable && browserOn b && vmWanted b) (browserGuestBinds b);
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
              root = true;
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
          # The app authorizes each CLI session through polkit, which in the
          # guest only that module answers.
          assertion = !(desktop && opInVm) || config.modules.apps.onepassword-system-auth.enable;
          message = "modules.apps.op-broker with 1Password in its VM needs modules.apps.onepassword-system-auth.enable (1Password authorizes the broker's CLI session through polkit).";
        }
        {
          assertion = desktop || cfg.serviceAccountTokenFile != null;
          message = "modules.apps.op-broker: auth = \"service-account\" needs serviceAccountTokenFile.";
        }
      ];

      warnings = lib.optional (desktop && !opInVm) ''
        op-broker: auth = "desktop" with 1Password in its container can't work: the
        1Password app only lets a CLI in after checking that the CLI's binary and its
        parent's are owned by root, by pid, and nixpak's user and pid namespaces make
        every host-root file look owned by uid 65534 and hide the broker's pids. Run
        1Password in its VM (modules.apps.onepassword.sandbox.mode = "vm"), or use
        auth = "service-account". See docs/op-broker.md.'';

      # 1Password refuses a CLI whose group has a gid below 1000 ("invalid group
      # attempted to connect"); NixOS reserves 31002 for it (ids.nix, as
      # programs._1password uses).
      users.groups.onepassword-cli.gid = config.ids.gids.onepassword-cli;
      # The same group in the guest, from boot on: 1Password checks a
      # connecting CLI's gid against it, and the app may start (and resolve the
      # group) before the guest broker's start script gets to create it.
      # Inert in the other VMs (one guest system for all).
      modules.sandbox.vm.guestModules = lib.mkIf (desktop && opInVm) [
        {
          users.groups.onepassword-cli.gid = config.ids.gids.onepassword-cli;
          # The CLI as 1Password's own install has it (and NixOS's
          # programs._1password): setgid onepassword-cli, so op's EFFECTIVE gid
          # is the group and its real gid stays the user's. A process whose real
          # gid is the group too (setpriv --regid) is refused: "invalid group
          # attempted to connect". The wrapper runs the root-owned tmpfs copy
          # (guestBrokerStart): the app also checks op's executable is
          # root-owned and not on FUSE, which the virtio-fs store is. /run is
          # nosuid; /run/wrappers isn't.
          security.wrappers.op = {
            source = "${guestOpDir}/op";
            owner = "root";
            group = "onepassword-cli";
            setuid = false;
            setgid = true;
          };
        }
      ];
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

      systemd.services.op-broker = lib.mkIf hostBroker {
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
        # The dialogs' display (see displayDir above).
        // lib.optionalAttrs (display != null) {
          WAYLAND_DISPLAY = display;
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

      # The host broker's own display, a security-context socket
      # (sandboxed-client view of the compositor) held while the user's
      # graphical session runs, and opened to the broker's uid by an ACL (the
      # helper binds it 0600; the directory is the user's, so only the user's
      # own processes ever touch it).
      systemd.user.services.op-broker-display = lib.mkIf ownDisplay {
        description = "Display for op-broker's dialogs";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        unitConfig.ConditionUser = user;
        serviceConfig = {
          # Upstream: the session's display, else the compositor socket name the
          # sandbox launchers pin (wayland-1). The socket appears (renamed into
          # place) once the compositor has the context; then the broker's uid
          # may connect. The helper dies with this script (PDEATHSIG).
          ExecStart = pkgs.writeShellScript "op-broker-display" ''
            set -eu
            export WAYLAND_DISPLAY="''${WAYLAND_DISPLAY:-wayland-1}"
            sock=${displayDir}/wayland-0
            ${pkgs.coreutils}/bin/rm -f "$sock"
            ${wlSecure}/bin/wayland-security-context hold "$sock" com.otisroot.op_broker &
            pid=$!
            for _ in $(${pkgs.coreutils}/bin/seq 1 100); do
              [ -S "$sock" ] && break
              kill -0 "$pid" 2>/dev/null || break
              ${pkgs.coreutils}/bin/sleep 0.05
            done
            if [ ! -S "$sock" ] || [ -L "$sock" ]; then
              echo "op-broker-display: no security-context socket" >&2
              kill "$pid" 2>/dev/null || true
              exit 1
            fi
            ${pkgs.acl}/bin/setfacl -m "u:${runAs}:rw" "$sock"
            wait "$pid"
          '';
          Restart = "on-failure";
          RestartSec = 2;
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
