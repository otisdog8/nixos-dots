# op-broker: per-item 1Password autofill for sandboxed browsers (docs/op-broker.md).
#
#   broker      bin/op-broker (serve | uplink | bridge), bin/op-broker-choose
#               (which login?) and bin/op-broker-notice (possible probing).
#               Runs next to 1Password, never in a browser sandbox.
#   nativeHost  bin/op-broker-native-host plus its manifests, for the browser
#               sandbox: lib/mozilla/native-messaging-hosts/ (Firefox family,
#               wrapFirefox's nativeMessagingHosts layout) and
#               etc/{chromium,opt/chrome}/native-messaging-hosts/.
#   extension   share/op-broker/{firefox,chromium}/ (unpacked) and
#               share/op-broker/op-broker.xpi (unsigned; see the doc).
#   ids         the pinned extension ids and native host name.
{
  lib,
  runCommand,
  stdenvNoCC,
  python3,
  bash,
  zenity,
  jq,
  zip,
  nodejs,
}:
let
  version = "0.1.0";

  ids = rec {
    nativeHost = "com.otisroot.op_broker";
    gecko = "op-broker@otisroot.com";
    # From `key` below (the public half of a key made once for this purpose; the
    # private half was not kept: nothing here is ever packed as a signed CRX).
    # Chromium derives the id from it, so it is stable across builds and paths.
    chromium = "ilegcnjonhgamikmijhnmbkeaackcfdl";
    chromiumOrigin = "chrome-extension://${chromium}/";
    chromiumKey = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkjrgUzwJ92EsFi86W97AJvU/pSLGZSVV9QeL1AE/x0azCE/+XmX3e+YEp78NOL4BBYqfqf8ZURjcUmLJj/ufFzhIbQYxcaPQPpO/ycsVGHdoC7kfsyVy87lKEDZZ2BK0+SUwFDRPPMl3NQy8uulGuGSQaJTXxH6TzXPivCDCLAI2zBVKVg4+o51tAEcdW4BbMMiXZlODDXRlIpYSz013pFAfoiMLQOtjINBhGgb6hTZgdCQPoYwND3c72NPjwRIUGZwSWDRm9j89J9UfxaDgE8rO2pbXH+Yke1AKfRP35n7jfrVcDDpNrMQPGlprWMF0qZQl5ikl5N5nT9NUux0UQQIDAQAB";
  };

  # -IS: ignore PYTHON* env vars and user site-packages (the native host runs in
  # a browser sandbox whose home the browser controls).
  pyScript = name: file: ''
    install -Dm755 /dev/null $out/bin/${name}
    { echo "#!${python3}/bin/python3 -IS"; cat ${file}; } > $out/bin/${name}
  '';

  broker = stdenvNoCC.mkDerivation {
    pname = "op-broker";
    inherit version;
    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./op_broker.py
        ./native_host.py
        ./choose.sh
        ./notice.sh
        ./tests
      ];
    };
    nativeBuildInputs = [ python3 ];
    dontConfigure = true;
    dontBuild = true;
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      patchShebangs tests
      # The broker's audit lines go to stderr too; show them only on failure.
      if ! python3 -W ignore -m unittest discover -s tests > test.log 2>&1; then
        cat test.log
        exit 1
      fi
      tail -n 3 test.log
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      ${pyScript "op-broker" "op_broker.py"}
      install -Dm755 /dev/null $out/bin/op-broker-choose
      { echo "#!${bash}/bin/bash"; sed 's|@zenity@|${zenity}/bin/zenity|g' choose.sh; } > $out/bin/op-broker-choose
      install -Dm755 /dev/null $out/bin/op-broker-notice
      { echo "#!${bash}/bin/bash"; sed 's|@zenity@|${zenity}/bin/zenity|g' notice.sh; } > $out/bin/op-broker-notice
      runHook postInstall
    '';
    meta = {
      description = "Per-item, per-origin 1Password approval broker for sandboxed browsers";
      mainProgram = "op-broker";
      platforms = lib.platforms.linux;
    };
  };

  hostBin = runCommand "op-broker-native-host-bin-${version}" { } (
    pyScript "op-broker-native-host" ./native_host.py
  );

  manifest =
    allowed:
    builtins.toJSON (
      {
        name = ids.nativeHost;
        description = "op-broker: forwards fill requests to the 1Password approval broker";
        path = "${hostBin}/bin/op-broker-native-host";
        type = "stdio";
      }
      // allowed
    );

  nativeHost =
    runCommand "op-broker-native-host-${version}"
      {
        firefox = manifest { allowed_extensions = [ ids.gecko ]; };
        chromium = manifest { allowed_origins = [ ids.chromiumOrigin ]; };
        passAsFile = [
          "firefox"
          "chromium"
        ];
        passthru = { inherit ids; };
      }
      ''
        mkdir -p $out/bin
        ln -s ${hostBin}/bin/op-broker-native-host $out/bin/
        install -Dm444 $firefoxPath $out/lib/mozilla/native-messaging-hosts/${ids.nativeHost}.json
        for d in etc/chromium etc/opt/chrome; do
          install -Dm444 $chromiumPath $out/$d/native-messaging-hosts/${ids.nativeHost}.json
        done
      '';

  extension =
    runCommand "op-broker-extension-${version}"
      {
        nativeBuildInputs = [
          jq
          zip
          nodejs
        ];
        passthru = {
          inherit ids;
          xpi = "${extension}/share/op-broker/op-broker.xpi";
          firefoxDir = "${extension}/share/op-broker/firefox";
          chromiumDir = "${extension}/share/op-broker/chromium";
        };
      }
      ''
        src=${./extension}
        node --check $src/background.js
        node --check $src/content.js
        share=$out/share/op-broker
        mkdir -p $share/firefox $share/chromium
        for d in firefox chromium; do
          cp $src/background.js $src/content.js $share/$d/
        done
        # One source manifest, one per browser: Firefox runs background.scripts
        # as an event page and needs the gecko id; Chromium runs the service
        # worker and gets the key that pins its id.
        jq --arg id ${ids.gecko} \
          'del(.background.service_worker)
           | .browser_specific_settings = {gecko: {id: $id, strict_min_version: "121.0"}}' \
          $src/manifest.json > $share/firefox/manifest.json
        jq --arg key ${ids.chromiumKey} \
          'del(.background.scripts) | .key = $key' \
          $src/manifest.json > $share/chromium/manifest.json
        # Deterministic XPI: fixed order and timestamps, no extra attributes.
        (cd $share/firefox && touch -d @315532800 * && zip -X -D -q -9 ../op-broker.xpi manifest.json background.js content.js)
      '';
in
{
  inherit
    broker
    nativeHost
    extension
    ids
    version
    ;
}
