# Declarative browser configuration: enterprise policies, force-installed
# extensions, search engine, homepage, DNS-over-HTTPS and hardware video decoding,
# shared by the browser app modules (nixos/modules/apps/{firefox,zen-browser,
# chromium,ungoogled-chromium,brave,captive-browser-chromium}.nix).
#
# Every browser runs under up to three implementations (nixpak, systemd, VM), so
# the configuration is delivered in ways all three see identically:
#
#   - Gecko (Firefox, Zen): the policies are baked into the browser PACKAGE
#     (wrapFirefox's extraPolicies → <libDir>/distribution/policies.json). The
#     package is modules.apps.<app>.package, which the nixpak/systemd backends wrap
#     and the VM runs straight from the host's /nix/store.
#
#   - Chromium family: Chromium reads managed policy only from a path compiled into
#     the binary (/etc/chromium/policies, /etc/brave/policies). Each app gets its
#     OWN file in that directory on the host (environment.etc:
#     <root>/{managed,recommended}/<app>.json, a symlink into the store) and binds
#     exactly that file read-only through capabilities.binds.ro (chromiumBinds).
#     Absolute binds keep their path everywhere: bwrap binds the file into its
#     tmpfs root (creating /etc/chromium/policies/managed inside the sandbox), and
#     the VM backend bind-mounts it into its virtio-fs share and grafts it onto the
#     same path in the guest's own /etc. Both resolve the /etc/static symlink chain
#     on the host, so the sandbox/guest sees a plain file and never needs the host's
#     /etc/static. Two apps sharing a policy root (chromium and ungoogled-chromium)
#     therefore still get separate policies: each sandbox only ever sees its own
#     file. (Only an unsandboxed Chromium on the host would read them all.)
#
# Chromium flags that can't be policies (Wayland, PipeWire capture, VA-API, no
# first-run page) go into the app's wrapper package (chromiumPackage).
{ lib }:
let
  inherit (lib) mkOption types;

  # Recursively drop attributes set to null, so `policies.Foo = null` removes a
  # generated policy (or sub-key) instead of emitting a JSON null.
  dropNulls =
    v: if lib.isAttrs v then lib.mapAttrs (_: dropNulls) (lib.filterAttrs (_: x: x != null) v) else v;

  # Generated policies, overridden key-by-key (recursively for attrsets; lists and
  # scalars are replaced) by the user's extra policies.
  mergePolicies = generated: extra: dropNulls (lib.recursiveUpdate generated extra);

  searchEngineType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = ''
          Engine name. Firefox selects its built-in engine of that name (Google,
          Bing, DuckDuckGo, …) and adds any other one from url/suggestUrl.
        '';
      };
      url = mkOption {
        type = types.str;
        description = "Search URL, with {searchTerms} where the query goes.";
      };
      suggestUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Suggestion URL, with {searchTerms}; null = no suggestions.";
      };
    };
  };

  policyType = types.attrsOf types.anything;
in
rec {
  # ── Well-known values ─────────────────────────────────────────────────────────
  # addons.mozilla.org: the always-latest signed XPI of an add-on, by its AMO slug.
  amo = slug: "https://addons.mozilla.org/firefox/downloads/latest/${slug}/latest.xpi";
  # Chrome Web Store update service (an extension's update_url).
  chromeWebStore = "https://clients2.google.com/service/update2/crx";

  duckduckgo = {
    name = "DuckDuckGo";
    url = "https://duckduckgo.com/?q={searchTerms}";
    suggestUrl = "https://duckduckgo.com/ac/?q={searchTerms}&type=list";
  };

  # Store extensions by family, ID → URL (the form browser.extensions takes).
  knownExtensions = {
    # uBlock Origin. Current Chromium no longer runs Manifest V2 extensions, so
    # Chromium gets its MV3 build, uBlock Origin Lite.
    ublock = {
      gecko."uBlock0@raymondhill.net" = amo "ublock-origin";
      chromium."ddkjiahejlhfcafbddmgiahcphecmpfh" = chromeWebStore;
    };
    # Vimium, keyboard navigation (AMO slug vimium-ff).
    vimium = {
      gecko."{d7742d87-e61d-4b78-b8a1-b469842139fa}" = amo "vimium-ff";
      chromium."dbepggeogbaibhgnhhndojpepiihcmeb" = chromeWebStore;
    };
  };

  # The official 1Password extension (AMO 1password-x-password-manager; Chrome Web
  # Store release and beta), blocked where op-broker's extension replaces it.
  onePasswordExtensions = {
    gecko = [ "{d634138d-c276-4fc8-924b-40a0ea21d284}" ];
    chromium = [
      "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
      "khgocmkkpikpnmmkgmdnfckapcdkgfaf"
    ];
  };

  # Default force-installed extensions: uBlock Origin and Vimium. Brave has its own
  # ad blocker, so it takes only Vimium; ungoogled-chromium and the captive-portal
  # browser get none, because installing from the Chrome Web Store would make them
  # talk to Google.
  extensionDefaults = {
    gecko = knownExtensions.ublock.gecko // knownExtensions.vimium.gecko;
    chromium = knownExtensions.ublock.chromium // knownExtensions.vimium.chromium;
  };

  # VA-API decode/encode (Chromium ≥ 131 feature names; the same list nixpkgs'
  # brave wrapper enables).
  vaapiFeatures = [
    "AcceleratedVideoDecodeLinuxGL"
    "AcceleratedVideoEncoder"
  ];

  # ── Options: modules.apps.<app>.browser.* (from the app's customOptions) ──────
  mkOptions =
    {
      appName,
      family, # "gecko" | "chromium"
      searchEngine ? duckduckgo,
      # Whether the app's package is built here (chromiumPackage / wrapFirefox),
      # so it honours hardwareVideoDecoding (and, Chromium family,
      # unpackedExtensions). false for apps with their own fixed package.
      withHardwareVideoDecoding ? true,
    }:
    {
      browser = {
        managePolicies = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Apply ${appName}'s declarative policies (everything under
            modules.apps.${appName}.browser). false = ship the browser without any
            managed policy, as before this module existed.
          '';
        };

        extensions = mkOption {
          type = types.attrsOf (types.nullOr types.str);
          default = { };
          example = lib.literalExpression (
            if family == "gecko" then
              ''{ "my-autofill@example.org" = "https://example.org/autofill/latest.xpi"; }''
            else
              ''{ abcdefghijklmnopabcdefghijklmnop = "https://example.org/autofill/updates.xml"; }''
          );
          description = ''
            Force-installed extensions, extension ID → URL. The user can't disable
            or remove them; the browser downloads and updates them itself.
            ${
              if family == "gecko" then
                ''
                  The URL is the add-on's install_url: an XPI (e.g.
                  "https://addons.mozilla.org/firefox/downloads/latest/<slug>/latest.xpi",
                  or an https/file URL of a self-hosted build). Release builds only
                  install SIGNED add-ons.''
              else
                ''
                  The URL is the extension's update_url: an update manifest (the Chrome
                  Web Store's is "${chromeWebStore}"; a self-hosted extension serves
                  its own updates.xml pointing at its .crx).''
            }
            Defaults: uBlock Origin and Vimium (per browser, see
            lib/browser-settings.nix). ${
              if family == "gecko" then
                "With modules.apps.op-broker serving this browser, its XPI is added here."
              else
                "(op-broker's extension goes through unpackedExtensions instead.)"
            } Set an ID to null to drop a default.
          '';
        };

        blockedExtensions = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Extension IDs that may not be installed (removed if already present).
            With modules.apps.op-broker serving this browser, the official 1Password
            extension is added.
          '';
        };

        searchEngine = mkOption {
          type = types.nullOr searchEngineType;
          default = searchEngine;
          description = ''
            Default search engine, applied as a default the user can still change in
            the browser (Firefox: set once per change of this value; Chromium: a
            RECOMMENDED policy). null = leave the browser's own default.
          '';
        };

        homepage = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Home button URL (a default the user can change). Startup/session restore is left alone. null = unmanaged.";
        };

        disableDnsOverHttps = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Turn the browser's built-in DNS-over-HTTPS off (and lock it), so it uses
            the system resolver, which already does encrypted DNS and which the
            sandbox network policies account for.
          '';
        };

        builtinPasswordManager = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Let the browser save and autofill passwords (and payment cards) itself.
            Off: 1Password handles them. Turning it off doesn't delete logins a
            profile already has${
              lib.optionalString (family == "chromium") ''
                ; Chromium may still fill ones saved before (its policy only stops
                saving new ones)''
            }.
          '';
        };

        policies = mkOption {
          type = policyType;
          default = { };
          example = lib.literalExpression "{ DisablePocket = null; SearchSuggestEnabled = false; }";
          description = ''
            Extra ${if family == "gecko" then "enterprise" else "MANDATORY (managed)"} policies, merged
            over the generated ones (attrsets recursively, other values replaced). null
            removes a generated policy. See ${
              if family == "gecko" then
                "https://mozilla.github.io/policy-templates/"
              else
                "https://chromeenterprise.google/policies/"
            }.
          '';
        };
      }
      // lib.optionalAttrs withHardwareVideoDecoding {
        hardwareVideoDecoding = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Prefer VA-API hardware video decoding (${
              if family == "gecko" then
                "media.ffmpeg.vaapi.enabled, as a user-changeable default"
              else
                "--enable-features=${lib.concatStringsSep "," vaapiFeatures}"
            }). Harmless where no VA-API driver exists (software fallback).
          '';
        };
      }
      // lib.optionalAttrs (family == "gecko") {
        allowUnsignedExtensions = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Let the browser install unsigned add-ons (the locked pref
            xpinstall.signatures.required = false). Only builds without
            MOZ_REQUIRE_SIGNING honour it: Developer Edition, Nightly, ESR,
            unbranded builds and Zen, not Firefox release. On whenever
            modules.apps.op-broker serves this browser (its XPI is unsigned).
          '';
        };
      }
      // lib.optionalAttrs (family == "chromium" && withHardwareVideoDecoding) {
        unpackedExtensions = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Unpacked extension directories the browser loads on every start
            (--load-extension in the app's wrapper package; not a policy, so it
            applies with managePolicies = false too). Works in Chromium-based
            builds; only Google-branded Chrome dropped the switch. With
            modules.apps.op-broker serving this browser, its extension directory is
            added.
          '';
        };
      }
      // lib.optionalAttrs (family == "chromium") {
        recommendedPolicies = mkOption {
          type = policyType;
          default = { };
          description = ''
            Extra RECOMMENDED policies (defaults the user may change), merged over the
            generated ones (search engine, homepage) like `policies`.
          '';
        };
      };
    };

  # ── Gecko (Firefox, Zen) ──────────────────────────────────────────────────────
  # Engines Firefox ships, by name: adding one of these again (SearchEngines.Add)
  # would only log a name clash, so they're just selected.
  geckoBuiltinEngines = [
    "Google"
    "Bing"
    "DuckDuckGo"
    "Ecosia"
    "Qwant"
    "Wikipedia (en)"
  ];

  geckoPolicies =
    b:
    let
      exts = lib.filterAttrs (_: u: u != null) b.extensions;
      se = b.searchEngine;
    in
    mergePolicies (
      {
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        DisablePocket = true;
        DisableFeedbackCommands = true;
        # Updates come from Nix; the in-app updater can only fail or nag.
        DisableAppUpdate = true;
        DontCheckDefaultBrowser = true;
        OverrideFirstRunPage = "";
        OverridePostUpdatePage = "";
        SkipTermsOfUse = true;

        # New tab / address bar without sponsored content or promotions. The user
        # keeps control of everything else there (Locked = false).
        FirefoxHome = {
          SponsoredTopSites = false;
          Pocket = false;
          SponsoredPocket = false;
          SponsoredStories = false;
          Snippets = false;
          Locked = false;
        };
        FirefoxSuggest = {
          SponsoredSuggestions = false;
          ImproveSuggest = false;
          Locked = false;
        };
        UserMessaging = {
          ExtensionRecommendations = false;
          FeatureRecommendations = false;
          UrlbarInterventions = false;
          SkipOnboarding = true;
          MoreFromMozilla = false;
          Locked = false;
        };

        Preferences =
          lib.optionalAttrs (!b.builtinPasswordManager) {
            "signon.autofillForms" = {
              Value = false;
              Status = "locked";
            };
            "signon.generation.enabled" = {
              Value = false;
              Status = "locked";
            };
          }
          // lib.optionalAttrs (b.hardwareVideoDecoding or false) {
            "media.ffmpeg.vaapi.enabled" = {
              Value = true;
              Status = "default";
            };
          }
          // lib.optionalAttrs b.allowUnsignedExtensions {
            "xpinstall.signatures.required" = {
              Value = false;
              Status = "locked";
            };
          };
      }
      # Passwords and payment cards live in 1Password: no built-in saving or
      # autofill. Saved logins already in a profile are kept on disk, just not
      # offered or reachable through about:logins.
      // lib.optionalAttrs (!b.builtinPasswordManager) {
        PasswordManagerEnabled = false;
        OfferToSaveLogins = false;
        AutofillCreditCardEnabled = false;
      }
      // lib.optionalAttrs b.disableDnsOverHttps {
        DNSOverHTTPS = {
          Enabled = false;
          Locked = true;
        };
      }
      // lib.optionalAttrs (exts != { } || b.blockedExtensions != [ ]) {
        ExtensionSettings =
          lib.genAttrs b.blockedExtensions (_: {
            installation_mode = "blocked";
          })
          // lib.mapAttrs (_: url: {
            installation_mode = "force_installed";
            install_url = url;
          }) exts;
      }
      # Default = applied once per change of the value (Firefox's
      # runOncePerModification), so the user can pick another engine afterwards.
      # Engines Firefox doesn't ship are added first.
      // lib.optionalAttrs (se != null) {
        SearchEngines = {
          Default = se.name;
        }
        // lib.optionalAttrs (!lib.elem se.name geckoBuiltinEngines) {
          Add = [
            (
              {
                Name = se.name;
                URLTemplate = se.url;
                Method = "GET";
              }
              // lib.optionalAttrs (se.suggestUrl != null) { SuggestURLTemplate = se.suggestUrl; }
            )
          ];
        };
      }
      // lib.optionalAttrs (b.homepage != null) {
        Homepage = {
          URL = b.homepage;
          Locked = false;
        };
      }
    ) b.policies;

  # ── op-broker ─────────────────────────────────────────────────────────────────
  # modules.apps.op-broker (nixos/modules/apps/op-broker.nix) as seen by one
  # browser app: `on` when it's enabled and serves appName, and its read-only
  # `extension` (ids, XPI, unpacked dirs). Only op-broker's own options are read,
  # never the browser's, and only in values (mkIf conditions / option values), so
  # it can't recurse into modules.apps; a host without that module gets `on = false`.
  opBrokerFor =
    config: appName:
    let
      opb =
        config.modules.apps.op-broker or {
          enable = false;
          browsers = [ ];
          extension = null;
        };
    in
    {
      on = opb.enable && lib.elem appName opb.browsers;
      inherit (opb) extension;
    };

  # customConfig part for a Gecko browser: the default extensions, op-broker's
  # extension when op-broker serves this browser, and the package with the
  # policies baked in (wrapFirefox's extraPolicies).
  geckoConfig =
    {
      appName,
      basePackage,
      defaultExtensions ? extensionDefaults.gecko,
    }:
    { config, ... }:
    let
      b = config.modules.apps.${appName}.browser;
      opb = opBrokerFor config appName;
    in
    lib.mkMerge [
      { modules.apps.${appName}.browser.extensions = lib.mapAttrs (_: lib.mkDefault) defaultExtensions; }
      # op-broker's unsigned XPI from the store (file://), which needs signature
      # checks off; the official 1Password extension it replaces is blocked.
      (lib.mkIf opb.on {
        modules.apps.${appName}.browser = {
          extensions.${opb.extension.ids.gecko} = lib.mkDefault opb.extension.xpiUrl;
          allowUnsignedExtensions = lib.mkDefault true;
          blockedExtensions = onePasswordExtensions.gecko;
        };
      })
      (lib.mkIf b.managePolicies {
        # mkDefault: a host that sets modules.apps.<app>.package itself wins.
        modules.apps.${appName}.package = lib.mkDefault (
          basePackage.override (old: {
            extraPolicies = (old.extraPolicies or { }) // geckoPolicies b;
          })
        );
      })
    ];

  # ── Chromium family ───────────────────────────────────────────────────────────
  chromiumPolicies =
    {
      b,
      # Family-specific mandatory defaults (e.g. Brave's own telemetry switches).
      extraManaged ? { },
    }:
    let
      exts = lib.filterAttrs (_: u: u != null) b.extensions;
      se = b.searchEngine;
    in
    {
      managed = mergePolicies (
        {
          # Telemetry and data collection.
          MetricsReportingEnabled = false;
          UrlKeyedAnonymizedDataCollectionEnabled = false;
          SpellCheckServiceEnabled = false;
          SafeBrowsingExtendedReportingEnabled = false;
          SafeBrowsingSurveysEnabled = false;
          FeedbackSurveysEnabled = false;
          # Ad-measurement / topics APIs ("Privacy Sandbox").
          PrivacySandboxPromptEnabled = false;
          PrivacySandboxAdTopicsEnabled = false;
          PrivacySandboxSiteEnabledAdsEnabled = false;
          PrivacySandboxAdMeasurementEnabled = false;
          # No default-browser nagging or promotional tabs.
          DefaultBrowserSettingEnabled = false;
          PromotionsEnabled = false;
        }
        # Passwords and payment cards live in 1Password.
        // lib.optionalAttrs (!b.builtinPasswordManager) {
          PasswordManagerEnabled = false;
          PasswordLeakDetectionEnabled = false;
          AutofillCreditCardEnabled = false;
        }
        // extraManaged
        // lib.optionalAttrs b.disableDnsOverHttps { DnsOverHttpsMode = "off"; }
        // lib.optionalAttrs (exts != { }) {
          ExtensionInstallForcelist = lib.mapAttrsToList (id: url: "${id};${url}") exts;
        }
        // lib.optionalAttrs (b.blockedExtensions != [ ]) {
          ExtensionInstallBlocklist = b.blockedExtensions;
        }
      ) b.policies;

      recommended = mergePolicies (
        lib.optionalAttrs (se != null) (
          {
            DefaultSearchProviderEnabled = true;
            DefaultSearchProviderName = se.name;
            DefaultSearchProviderSearchURL = se.url;
          }
          // lib.optionalAttrs (se.suggestUrl != null) { DefaultSearchProviderSuggestURL = se.suggestUrl; }
        )
        // lib.optionalAttrs (b.homepage != null) {
          HomepageLocation = b.homepage;
          HomepageIsNewTabPage = false;
        }
      ) b.recommendedPolicies;
    };

  # The policy files an app binds (app-spec capabilities.binds.ro). Missing ones
  # (policies off, or nothing recommended) are skipped by every backend.
  chromiumBinds =
    { appName, policyRoot }:
    [
      "${policyRoot}/managed/${appName}.json"
      "${policyRoot}/recommended/${appName}.json"
    ];

  # customConfig part for a Chromium-family browser: default extensions, op-broker's
  # extension when op-broker serves this browser, the per-app policy files under
  # policyRoot, and (with mkPackage) the wrapper package built from the host's
  # hardwareVideoDecoding and unpackedExtensions.
  chromiumConfig =
    {
      appName,
      policyRoot, # e.g. "/etc/chromium/policies"
      extraManaged ? { },
      defaultExtensions ? extensionDefaults.chromium,
      # { hardwareVideoDecoding, loadExtensions } → package; null = leave the
      # package alone.
      mkPackage ? null,
    }:
    {
      config,
      pkgs,
      ...
    }:
    let
      b = config.modules.apps.${appName}.browser;
      p = chromiumPolicies { inherit b extraManaged; };
      json = pkgs.formats.json { };
      etcDir = lib.removePrefix "/etc/" policyRoot;
      opb = opBrokerFor config appName;
    in
    lib.mkMerge [
      { modules.apps.${appName}.browser.extensions = lib.mapAttrs (_: lib.mkDefault) defaultExtensions; }
      # op-broker's extension, unpacked from the store with --load-extension (its
      # manifest `key` pins the id; a force-install policy would need a signed CRX
      # behind an update URL); the official 1Password extension it replaces is
      # blocked.
      (lib.mkIf opb.on {
        modules.apps.${appName}.browser = {
          blockedExtensions = onePasswordExtensions.chromium;
        }
        // lib.optionalAttrs (mkPackage != null) {
          unpackedExtensions = [ opb.extension.chromiumDir ];
        };
      })
      (lib.mkIf b.managePolicies {
        environment.etc."${etcDir}/managed/${appName}.json".source =
          json.generate "${appName}-managed-policies.json" p.managed;
      })
      (lib.mkIf (b.managePolicies && p.recommended != { }) {
        environment.etc."${etcDir}/recommended/${appName}.json".source =
          json.generate "${appName}-recommended-policies.json" p.recommended;
      })
      (lib.mkIf (mkPackage != null) {
        modules.apps.${appName}.package = lib.mkDefault (mkPackage {
          hardwareVideoDecoding = b.hardwareVideoDecoding;
          loadExtensions = b.unpackedExtensions or [ ];
        });
      })
    ];

  # Wrapper that forces native Wayland and the PipeWire screen capturer (a dedicated
  # uid can't auth to XWayland), optionally VA-API, and skips the first-run page.
  # ALL features go in ONE --enable-features: Chromium keeps only the last copy of a
  # repeated switch, and these flags come after the ones the nixpkgs wrapper adds
  # (so e.g. brave's own VA-API --enable-features would otherwise be dropped).
  # loadExtensions: unpacked extension directories, in ONE --load-extension for the
  # same reason. (No --disable-features here: it would replace the list brave's
  # wrapper passes.)
  chromiumPackage =
    {
      pkgs,
      name,
      base,
      bin,
      hardwareVideoDecoding ? true,
      features ? [ ],
      loadExtensions ? [ ],
    }:
    let
      allFeatures = lib.unique (
        [ "WebRtcPipeWireCapturer" ] ++ lib.optionals hardwareVideoDecoding vaapiFeatures ++ features
      );
      loadFlag = "--load-extension=${lib.concatStringsSep "," (lib.unique loadExtensions)}";
      flags = [
        "--ozone-platform=wayland"
        "--enable-features=${lib.concatStringsSep "," allFeatures}"
        "--no-first-run"
      ]
      ++ lib.optional (loadExtensions != [ ]) loadFlag;
    in
    pkgs.symlinkJoin {
      inherit name;
      paths = [ base ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        rm $out/bin/${bin}
        makeWrapper ${base}/bin/${bin} $out/bin/${bin} \
          --add-flags "${lib.concatStringsSep " " flags}"
      '';
    };
}
