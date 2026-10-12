# The wp_security_context_v1 socket helper (see wayland-security-context.py),
# shared by the nixpak and systemd backends and installed for manual checks.
pkgs:
# -IS: ignore PYTHON* env vars and user site-packages (see mountHelper in
# lib/backends/systemd.nix).
pkgs.writeScriptBin "wayland-security-context" (
  "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ./wayland-security-context.py
)
