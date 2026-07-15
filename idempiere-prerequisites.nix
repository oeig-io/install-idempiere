# idempiere-prerequisites.nix
# NixOS module for iDempiere ERP prerequisites (Phase 1)
# Based on: https://wiki.idempiere.org/en/Installing_iDempiere
#
# This module sets up:
#   - Java (OpenJDK 17)
#   - PostgreSQL 17
#   - idempiere user/group
#   - Required directories
#
# Workflow:
#   1. Add this to configuration.nix: imports = [ ./idempiere-prerequisites.nix ];
#   2. Run: sudo nixos-rebuild switch
#   3. Run Ansible: ansible-playbook -i inventory.ini idempiere-install.yml -e "import_database=true"
#   4. Add service: imports = [ ./idempiere-prerequisites.nix ./idempiere-service.nix ];
#   5. Run: sudo nixos-rebuild switch

{ config, pkgs, lib, ... }:

let
  idempiere = {
    user = "idempiere";
    group = "idempiere";
    installDir = "/opt/idempiere-server";
  };

  db = {
    name = "idempiere";
    user = "adempiere";
    # Password is generated randomly at first boot - see activationScripts.pgpass
    host = "localhost";
    port = 5432;
    # Allow remote (non-localhost) PostgreSQL connections.
    #   true  -> binds all interfaces, opens firewall port 5432, and adds
    #            pg_hba rules for all IPv4/IPv6 clients. Access is still
    #            password-gated via scram-sha-256 (no anonymous access), but
    #            the firewall becomes the real network boundary - only enable
    #            on hosts behind a trusted network (private bridge / VPN).
    #   false -> localhost-only (original secure default).
    remoteAccess = true;
  };

  # Wrapper script to connect to iDempiere database (uses ~/.pgpass for auth)
  psqli = pkgs.writeShellScriptBin "psqli" ''
    exec ${pkgs.postgresql_17}/bin/psql \
      -h ${db.host} \
      -p ${toString db.port} \
      -U ${db.user} \
      -d ${db.name} \
      "$@"
  '';

  # pg_durable: durable SQL functions, built as a native PG 17 extension.
  # Always installed (see pg-durable.nix for the build recipe and rationale).
  pgDurable = pkgs.callPackage ./pg-durable.nix { postgresql = pkgs.postgresql_17; };

  # pg_durable is a cluster-level singleton: one background worker bound to one
  # "home" database (pg_durable.database). We home it in `postgres` to keep the
  # df.*/duroxide.* state out of the iDempiere application schema; workflows can
  # still target the `idempiere` database via df.start(..., database => ...).
  pgDurableHomeDb = "postgres";
  pgDurableWorkerRole = "postgres"; # must be a superuser (bypasses RLS)

in {
  #############################################################################
  # Timezone Configuration - Default to America/Chicago
  # Can be overridden by container-management/launch.sh when needed
  #############################################################################
  time.timeZone = "America/Chicago";

  #############################################################################
  # Compatibility: iDempiere scripts expect /bin/bash
  # NixOS doesn't have /bin/bash by default
  #############################################################################
  system.activationScripts.binbash = ''
    mkdir -p /bin
    ln -sf ${pkgs.bash}/bin/bash /bin/bash
  '';

  system.activationScripts.opencode-dirs = ''
    mkdir -p /home/${idempiere.user}/.local/share/opencode
    chown ${idempiere.user}:${idempiere.group} /home/${idempiere.user}/.local/share/opencode
  '';

  # enable netbird - must bring up manually
  services.netbird.enable = true;

  #############################################################################
  # IPv6 Configuration - Disable temporary addresses for stable addressing
  #############################################################################
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.use_tempaddr" = lib.mkForce 0;
    "net.ipv6.conf.default.use_tempaddr" = lib.mkForce 0;
  };

  # Create .pgpass for idempiere user (required for psqli and other pg tools)
  # Password is generated randomly on first run and persisted across rebuilds
  system.activationScripts.pgpass = ''
    PGPASS_FILE="/home/${idempiere.user}/.pgpass"

    # Only generate password if .pgpass doesn't exist
    if [ ! -f "$PGPASS_FILE" ]; then
      # Generate a random 32-character alphanumeric password
      DB_PASSWORD=$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -dc 'a-zA-Z0-9' | ${pkgs.coreutils}/bin/head -c 32)
      echo "${db.host}:${toString db.port}:${db.name}:${db.user}:$DB_PASSWORD" > "$PGPASS_FILE"
      chown ${idempiere.user}:${idempiere.group} "$PGPASS_FILE"
      chmod 600 "$PGPASS_FILE"
      echo "Generated new database password in $PGPASS_FILE"
    else
      echo "Using existing database password from $PGPASS_FILE"
    fi
  '';

  #############################################################################
  # System packages - Prerequisites per official guide
  # https://wiki.idempiere.org/en/Install_Prerequisites
  #############################################################################
  environment.systemPackages = with pkgs; [
    # JDK 17 (not JRE) - required for jar command used in scripts
    openjdk17

    # PostgreSQL client tools (psql, pg_dump, etc.)
    postgresql_17

    # Utilities needed for installation
    wget
    unzip
    coreutils
    gnused
    gawk
    jq       # JSON processing for REST API scripting
    expect   # For OSGi plugin deployment via telnet
    inetutils  # Provides telnet for OSGi console access

    # Python (required for Ansible to work locally)
    python3

    # Maven - for building iDempiere from source
    maven

    # Ansible for orchestration (run from this machine or control node)
    ansible

    # Quick connect to iDempiere database (psqli)
    psqli

    # SVG to PNG converter for environment banners (lighter than ImageMagick)
    resvg

    # AI coding assistants
    opencode
    aichat

    # Encryption for secrets management
    age
  ];

  #############################################################################
  # Java environment - OpenJDK 17 LTS per official guide
  #############################################################################
  programs.java = {
    enable = true;
    package = pkgs.openjdk17;
  };

  # Ensure JAVA_HOME is set system-wide
  environment.variables = {
    JAVA_HOME = "${pkgs.openjdk17}";
  };

  #############################################################################
  # PostgreSQL 17 service
  # https://wiki.idempiere.org/en/Install_Prerequisites#PostgreSQL
  #############################################################################
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;

    # listen_addresses: all interfaces when remote access is enabled,
    # otherwise localhost only. NixOS forces "*" when enableTCPIP = true,
    # so use lib.mkForce to control it explicitly.
    enableTCPIP = true;
    settings = {
      port = db.port;
      listen_addresses = lib.mkForce (if db.remoteAccess then "*" else "localhost");
      # pg_durable registers a background worker via shared_preload_libraries.
      # This requires a PostgreSQL restart to take effect (not a reload).
      shared_preload_libraries = "pg_durable";
      "pg_durable.database" = pgDurableHomeDb;
      "pg_durable.worker_role" = pgDurableWorkerRole;
      # We run durable functions as the postgres superuser on this cluster,
      # so allow superuser-submitted instances (off by default). Matches the
      # upstream Docker image's configuration.
      "pg_durable.enable_superuser_instances" = "on";
    };

    # Native PG 17 build of pg_durable (see pg-durable.nix).
    extraPlugins = _: [ pgDurable ];

    # Authentication - scram-sha-256 per official guide
    # The postgres user password will be set by Ansible
    authentication = lib.mkForce (''
      # TYPE  DATABASE        USER            ADDRESS                 METHOD
      # Local connections
      local   all             postgres                                peer
      local   all             all                                     scram-sha-256
      # IPv4/IPv6 loopback connections use trust.
      # pg_durable's background worker connects over loopback as many different
      # roles (the worker role and each submitting login role) with no stored
      # credentials, delegating auth entirely to pg_hba - this requires trust
      # (or peer) for local connections. See pg_durable docs/user-isolation.md.
      # Scope is loopback-only; remote clients still authenticate via
      # scram-sha-256 below. iDempiere's loopback connections are unaffected
      # (trust accepts the password it sends).
      host    all             all             127.0.0.1/32            trust
      host    all             all             ::1/128                 trust
    '' + lib.optionalString db.remoteAccess ''
      # Remote connections (all networks) - password-gated via scram-sha-256
      host    all             all             0.0.0.0/0               scram-sha-256
      host    all             all             ::/0                    scram-sha-256
    '');

    # Note: Database and role creation handled by Ansible after
    # iDempiere's RUN_ImportIdempiere.sh which creates the schema
  };

  #############################################################################
  # iDempiere system user
  # https://wiki.idempiere.org/en/Installing_from_Installers
  # "DO NOT install idempiere as root"
  #############################################################################
  users.users.${idempiere.user} = {
    isSystemUser = true;
    group = idempiere.group;
    home = "/home/${idempiere.user}";
    createHome = true;
    shell = pkgs.bash;
    description = "iDempiere ERP service user";
  };

  users.groups.${idempiere.group} = {};

  #############################################################################
  # iDempiere directories
  #############################################################################
  systemd.tmpfiles.rules = [
    # Create install directory owned by idempiere user
    "d ${idempiere.installDir} 0755 ${idempiere.user} ${idempiere.group} -"
    # Log directory
    "d /var/log/idempiere 0755 ${idempiere.user} ${idempiere.group} -"
    # Storage provider directories (for attachments, archives, images, DMS)
    # Restricted permissions (0750) - may contain sensitive data
    # See: planning/storage-provider-directories.md
    "d /opt/idempiere-doc-attachment 0750 ${idempiere.user} ${idempiere.group} -"
    "d /opt/idempiere-doc-archive 0750 ${idempiere.user} ${idempiere.group} -"
    "d /opt/idempiere-doc-image 0750 ${idempiere.user} ${idempiere.group} -"
    "d /opt/idempiere-doc-dms-content 0750 ${idempiere.user} ${idempiere.group} -"
    "d /opt/idempiere-doc-dms-thumbnail 0750 ${idempiere.user} ${idempiere.group} -"
    # OpenCode directories (for AI assistant integration) - contains API keys
    "d /home/idempiere/.local/share/opencode 0700 ${idempiere.user} ${idempiere.group} -"
    "d /home/idempiere/.opencode 0700 ${idempiere.user} ${idempiere.group} -"
  ];

  #############################################################################
  # Firewall
  # iDempiere HTTP/HTTPS ports (8080/8443) are left for the nginx module / your
  # own config to open. PostgreSQL 5432 is opened only when db.remoteAccess is
  # enabled above.
  #############################################################################
  networking.firewall.allowedTCPPorts =
    lib.optionals db.remoteAccess [ 5432 ];
}
