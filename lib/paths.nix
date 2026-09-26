# Path helpers shared by the sandbox layers.
{ lib }:
rec {
  # "a//b/c/" → [ "a" "b" "c" ]
  components = p: lib.filter (c: c != "") (lib.splitString "/" p);

  # Component-wise strict ancestor: ".config" is a parent of ".config/nvim", but
  # ".config/ab" is not a parent of ".config/abc".
  isStrictParent =
    a: b:
    let
      ca = components a;
      cb = components b;
    in
    lib.length ca < lib.length cb && lib.take (lib.length ca) cb == ca;

  # How an extraBinds / capabilities.binds entry resolves: "/abs" as-is;
  # ".", "..", "./x", "../x" relative to $PWD; anything else (".ssh" included)
  # relative to $HOME.
  isAbsolute = p: lib.hasPrefix "/" p;
  isPwdRelative = p: p == "." || p == ".." || lib.hasPrefix "./" p || lib.hasPrefix "../" p;
}
