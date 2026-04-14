# GSD (Get Shit Done) - AI-powered coding agent

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  let
    version = "2.74.0";

    # Pin npm registry metadata to this instant so `npm install --package-lock-only`
    # produces a reproducible lockfile. Bump alongside `version`.
    registrySnapshot = "2026-04-14T00:00:00Z";

    stripWorkspaces = pkgs.writeText "strip-workspaces.py" ''
      import json
      with open("package.json") as f:
          d = json.load(f)
      d.pop("workspaces", None)
      with open("package.json", "w") as f:
          json.dump(d, f, indent=2)
    '';

    gsd-pi-src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/gsd-pi/-/gsd-pi-${version}.tgz";
      hash = "sha256-VNCoTSm/tsjzP9FhUgznFuvJ5a0XXr9hmIZVL/oNfwM=";
    };

    gsd-pi-lockfile = pkgs.stdenvNoCC.mkDerivation {
      name = "gsd-pi-package-lock.json";
      src = gsd-pi-src;
      sourceRoot = "package";
      nativeBuildInputs = [ pkgs.nodejs_22 pkgs.python3 pkgs.cacert ];
      buildPhase = ''
        export HOME=$(mktemp -d)
        export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        ${pkgs.python3}/bin/python3 ${stripWorkspaces}
        npm install --package-lock-only --ignore-scripts --before=${registrySnapshot}
      '';
      installPhase = ''
        cp package-lock.json $out
      '';
      outputHashMode = "flat";
      outputHashAlgo = "sha256";
      outputHash = "sha256-1nO3GMdwqoUG5kvObj/a6pTKZumcZTOTpa2dpx6UGwo=";
    };

    gsd-pi = pkgs.buildNpmPackage {
      pname = "gsd-pi";
      inherit version;

      src = gsd-pi-src;

      sourceRoot = "package";

      postPatch = ''
        ${pkgs.python3}/bin/python3 ${stripWorkspaces}
        cp ${gsd-pi-lockfile} package-lock.json
      '';

      npmDepsHash = "sha256-7xOPtTTVMcAd9woPhou7pb/9BWw+It2joQq8ksvCghQ=";
      npmDepsFetcherVersion = 2;
      makeCacheWritable = true;

      dontNpmBuild = true;
      npmFlags = [ "--ignore-scripts" ];

      postInstall = ''
        node $out/lib/node_modules/gsd-pi/scripts/link-workspace-packages.cjs

        mkdir -p $out/bin
        makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/gsd \
          --add-flags "$out/lib/node_modules/gsd-pi/dist/loader.js"
        makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/gsd-cli \
          --add-flags "$out/lib/node_modules/gsd-pi/dist/loader.js"
        ln -s $out/bin/gsd $out/bin/pi
      '';

      nativeBuildInputs = [ pkgs.makeWrapper ];

      meta = with pkgs.lib; {
        description = "GSD - Get Shit Done coding agent";
        homepage = "https://github.com/gsd-build/gsd-2";
        license = licenses.mit;
      };
    };
  in
  {
    imports = [
      ../../../lib/app-spec.nix
      ../../../lib/features/xdg.nix
      ../../../lib/features/network.nix
      ../../../lib/features/system-bin.nix
      ../../../lib/features/cwd.nix
    ];

    config.app = {
      name = "gsd";
      packageName = "gsd";
      package = gsd-pi;

      persistence.user.persist = [
        ".gsd"
      ];

      nixpakModules = [
        (
          { sloth, ... }:
          {
            bubblewrap.bind.rw = [
              (sloth.concat' sloth.homeDir "/.gsd")
              (sloth.env "PWD")
            ];
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.gsd.sandbox.enable = lib.mkDefault true;
        };
    };
  }
)
