# GSD (Get Shit Done) - AI-powered coding agent

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  let
    stripWorkspaces = pkgs.writeText "strip-workspaces.py" ''
      import json
      with open("package.json") as f:
          d = json.load(f)
      d.pop("workspaces", None)
      with open("package.json", "w") as f:
          json.dump(d, f, indent=2)
    '';

    gsd-pi-src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/gsd-pi/-/gsd-pi-2.66.1.tgz";
      hash = "sha256-yHS7VxX/ofzHjs2KOhpE1ErTHfVVoU2IbtXhr0bk/2E=";
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
        npm install --package-lock-only --ignore-scripts
      '';
      installPhase = ''
        cp package-lock.json $out
      '';
      outputHashMode = "flat";
      outputHashAlgo = "sha256";
      outputHash = "sha256-nnMRLFgTEvHiuCkabCaA68E5vuCO7CQishyLYsS2i9U=";
    };

    gsd-pi = pkgs.buildNpmPackage rec {
      pname = "gsd-pi";
      version = "2.66.1";

      src = gsd-pi-src;

      sourceRoot = "package";

      postPatch = ''
        ${pkgs.python3}/bin/python3 ${stripWorkspaces}
        cp ${gsd-pi-lockfile} package-lock.json
      '';

      npmDepsHash = "sha256-8OTgrm+RVzYcWwR+xPsPimCMinvS7sUVzucpn9pfbkI=";
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
