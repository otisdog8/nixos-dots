# Temporary folder grants for sandbox VMs (grants.py), host and guest side.
# -IS: ignore PYTHON* env vars and user site-packages.
pkgs:
pkgs.writeScriptBin "sbx-grants" (
  "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ./grants.py
)
