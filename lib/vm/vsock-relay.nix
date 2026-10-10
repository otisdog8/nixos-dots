# The vsock service relay (vsock-relay.py), used on both sides of a sandbox VM.
# -IS: ignore PYTHON* env vars and user site-packages. Its D-Bus authentication
# tests (tests/test_vsock_relay.py) run at build time, against a private
# dbus-daemon too.
pkgs:
pkgs.stdenvNoCC.mkDerivation {
  name = "vsock-relay";
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./vsock-relay.py
      ./tests/test_vsock_relay.py
    ];
  };
  nativeBuildInputs = [
    pkgs.python3
    pkgs.dbus
  ];
  dontConfigure = true;
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    if ! python3 -m unittest discover -s tests -p 'test_vsock_relay.py' -v > test.log 2>&1; then
      cat test.log
      exit 1
    fi
    tail -n 3 test.log
    runHook postCheck
  '';
  installPhase = ''
    install -Dm755 /dev/null $out/bin/vsock-relay
    { echo "#!${pkgs.python3}/bin/python3 -IS"; cat vsock-relay.py; } > $out/bin/vsock-relay
  '';
  meta.mainProgram = "vsock-relay";
}
