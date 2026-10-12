# The root steps of a sandbox VM (root.py): staging the paths users choose,
# cleanup, the GPU backend's sockets, cameras, core scheduling. Each runs from
# a confined root unit of lib/vm/instance.nix. Its unprivileged tests:
# python3 -m unittest discover -s lib/vm/tests -p 'test_root.py'.
# -IS: ignore PYTHON* env vars and user site-packages.
pkgs:
pkgs.writeScriptBin "sbx-vm-root" (
  "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ./root.py
)
