{
  config,
  lib,
  pkgs,
  ...
}:
{
  services.garage = {
    enable = true;
    package = pkgs.garage;

    environmentFile = "/persist/garage.env";

    settings = {
      # Single-node setup
      replication_factor = 1;

      # Storage directories
      # Metadata on fast SSD (persisted via impermanence)
      metadata_dir = "/var/lib/garage/meta";
      # Data on bcachefs
      data_dir = "/mnt/bcachefs/garage/data";

      # Database engine - LMDB is recommended for performance
      db_engine = "lmdb";

      # Compression for stored blocks
      compression_level = 1;

      # RPC configuration
      rpc_bind_addr = "[::]:3901";

      # S3 API
      s3_api = {
        api_bind_addr = "[::]:3900";
        s3_region = "garage";
      };

      # Admin API
      admin = {
        api_bind_addr = "[::]:3903";
      };
    };
  };

  # Firewall
  networking.firewall.allowedTCPPorts = [
    3900 # S3 API
    3901 # RPC
    3903 # Admin API
  ];

  # Persistence for metadata directory
  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/garage";
      user = "garage";
      group = "garage";
      mode = "0700";
    }
  ];
}
