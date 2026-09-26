# Run commands inside a running container sandbox (sbx-exec.py; persistent groups).
# -IS: ignore PYTHON* env vars and user site-packages.
pkgs:
pkgs.writeScriptBin "sbx-exec" (
  "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ./sbx-exec.py
)
