# sbx-polkit-agent (polkit-agent.py): the guest-side half of "system
# authentication" for apps in a VM. Its tests (tests/test_polkit_agent.py) run
# at build time against a private dbus-daemon and a fake polkitd.
pkgs:
let
  python = pkgs.python3.withPackages (ps: [ ps.jeepney ]);
in
pkgs.stdenvNoCC.mkDerivation {
  name = "sbx-polkit-agent";
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./polkit-agent.py
      ./tests/test_polkit_agent.py
    ];
  };
  nativeBuildInputs = [
    python
    pkgs.dbus
    pkgs.coreutils
  ];
  dontConfigure = true;
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    if ! DBUS_DAEMON=${pkgs.dbus}/bin/dbus-daemon python3 -m unittest discover -s tests -v > test.log 2>&1; then
      cat test.log
      exit 1
    fi
    tail -n 3 test.log
    runHook postCheck
  '';
  installPhase = ''
    install -Dm755 /dev/null $out/bin/sbx-polkit-agent
    { echo "#!${python}/bin/python3 -IS"; cat polkit-agent.py; } > $out/bin/sbx-polkit-agent
  '';
  meta.mainProgram = "sbx-polkit-agent";
}
