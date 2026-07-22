# Pure-function unit tests for lib/storage.nix.
#
# Run:  nix eval --impure --raw -f lib/storage-tests.nix
# (prints "ALL STORAGE TESTS PASS" or throws with the failing cases.)
{
  lib ? (import <nixpkgs> { }).lib,
}:
let
  storage = import ./storage.nix { inherit lib; };

  mkEntry = path: tier: {
    inherit path tier;
    location = "stash";
    type = "dir";
    mode = "0700";
  };

  # (#3) Parent-first ordering: a child target must sort after its parent so the
  # backend binds the parent first (cross-tier profile + cache is the real case).
  ord = storage {
    appName = "t";
    appCfg.storage = [
      (mkEntry ".config/app/Cache" "cache") # declared child-first on purpose
      (mkEntry ".config/app" "persist")
    ];
  };
  test3_parentFirst =
    (map (e: e.path) ord.entries) == [
      ".config/app"
      ".config/app/Cache"
    ];

  # (#2) Same-tier nesting is illegal → a failing assertion is produced.
  sameTier = storage {
    appName = "t";
    appCfg.storage = [
      (mkEntry ".config/app" "persist")
      (mkEntry ".config/app/sub" "persist")
    ];
  };
  test2_sameTierFails = sameTier.assertions != [ ] && !(lib.head sameTier.assertions).assertion;

  # (#2) Cross-tier nesting is allowed → no assertion.
  crossTier = storage {
    appName = "t";
    appCfg.storage = [
      (mkEntry ".config/app" "persist")
      (mkEntry ".config/app/Cache" "cache")
    ];
  };
  test2_crossTierOk = crossTier.assertions == [ ];

  # Sibling paths that merely share a string prefix must NOT be flagged as nested
  # (component-wise prefix, not string prefix): ".config/ab" vs ".config/abc".
  siblings = storage {
    appName = "t";
    appCfg.storage = [
      (mkEntry ".config/ab" "persist")
      (mkEntry ".config/abc" "persist")
    ];
  };
  test2_stringPrefixNotNested = siblings.assertions == [ ];

  results = {
    inherit
      test3_parentFirst
      test2_sameTierFails
      test2_crossTierOk
      test2_stringPrefixNotNested
      ;
  };
in
if lib.all (x: x) (lib.attrValues results) then
  "ALL STORAGE TESTS PASS"
else
  throw "storage tests FAILED: ${builtins.toJSON results}"
