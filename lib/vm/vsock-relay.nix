# The vsock service relay (vsock-relay.py), used on both sides of a sandbox VM.
# -IS: ignore PYTHON* env vars and user site-packages.
pkgs:
pkgs.writeScriptBin "vsock-relay" (
  "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ./vsock-relay.py
)
