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

in {
  #############################################################################
  # Compatibility: iDempiere scripts expect /bin/bash
  # NixOS doesn't have /bin/bash by default
  #############################################################################
  system.activationScripts.binbash = ''
    mkdir -p /bin
    ln -sf ${pkgs.bash}/bin/bash /bin/bash
  '';

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

    # Listen on localhost only (change for remote DB access)
    enableTCPIP = true;
    settings = {
      port = db.port;
      listen_addresses = lib.mkForce "localhost";
    };

    # Authentication - scram-sha-256 per official guide
    # The postgres user password will be set by Ansible
    authentication = lib.mkForce ''
      # TYPE  DATABASE        USER            ADDRESS                 METHOD
      # Local connections
      local   all             postgres                                peer
      local   all             all                                     scram-sha-256
      # IPv4 local connections
      host    all             all             127.0.0.1/32            scram-sha-256
      # IPv6 local connections
      host    all             all             ::1/128                 scram-sha-256
    '';

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
  ];

  #############################################################################
  # Firewall - Uncomment to open iDempiere ports
  #############################################################################
  # networking.firewall.allowedTCPPorts = [
  #   8080   # HTTP
  #   8443   # HTTPS
  # ];
}
