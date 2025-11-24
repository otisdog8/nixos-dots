{ lib }:

{
  # Helper functions for declaring persistence across different subvolumes

  # Convenience for persisting .config directories
  persistDotConfig = name: {
    persist = [ ".config/${name}" ];
  };

  # Convenience for persisting .local/share directories
  persistXDGData = name: {
    persist = [ ".local/share/${name}" ];
  };

  # Convenience for persisting both config and data
  persistConfigAndData = name: {
    persist = [ ".config/${name}" ".local/share/${name}" ];
  };

  # Electron app persistence pattern (config + volatile caches)
  electronAppPersistence = name: {
    persist = [ ".config/${name}" ];
    volatileCache = [
      ".config/${name}/Cache"
      ".config/${name}/GPUCache"
      ".config/${name}/Code Cache"
      ".config/${name}/DawnCache"
    ];
  };

  # Browser persistence pattern (config + extensive volatile caches)
  browserPersistence =
    name:
    {
      persist = [ ".config/${name}" ];
      volatileCache = [
        ".cache/${name}"
        ".config/${name}/Default/Service Worker"
        ".config/${name}/Service Worker"
        ".config/${name}/ShaderCache"
      ];
    };

  # Gaming app persistence (config + data, with option for large storage)
  gamingAppPersistence =
    name:
    { useLarge ? true }:
    {
      persist = [ ".config/${name}" ];
      large = lib.optionals useLarge [ ".local/share/${name}" ];
    };

  # Development tool persistence (config + data + cache)
  devToolPersistence = name: {
    persist = [ ".config/${name}" ".local/share/${name}" ];
    cache = [ ".cache/${name}" ];
  };

  # System-level baked (immutable) persistence
  # Used for secrets, keys, certificates set at install time
  bakedSystemPersistence =
    paths:
    {
      baked = paths;
    };

  # Merge multiple persistence declarations
  mergePersistence = declarations:
    let
      allDecls = lib.filter (d: d != null && d != { }) declarations;
    in
    {
      persist = lib.unique (lib.flatten (map (d: d.persist or [ ]) allDecls));
      large = lib.unique (lib.flatten (map (d: d.large or [ ]) allDecls));
      cache = lib.unique (lib.flatten (map (d: d.cache or [ ]) allDecls));
      volatileCache = lib.unique (lib.flatten (map (d: d.volatileCache or [ ]) allDecls));
      baked = lib.unique (lib.flatten (map (d: d.baked or [ ]) allDecls));
    };

  # Create persistence config for a user with mode restrictions
  # Useful for sensitive directories like .ssh, .gnupg
  persistWithMode =
    {
      path,
      mode ? "0700",
      subvolume ? "persist",
    }:
    {
      ${subvolume} = [
        {
          directory = path;
          inherit mode;
        }
      ];
    };

  # Persist a file (not a directory)
  persistFile =
    {
      path,
      subvolume ? "persist",
    }:
    {
      ${subvolume} = [ path ];
    };
}
