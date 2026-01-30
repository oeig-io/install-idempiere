# idempiere-service.nix
# NixOS module for iDempiere systemd service (Phase 2)
#
# IMPORTANT: Only add this AFTER running the Ansible installation playbook!
#
# Workflow:
#   1. Prerequisites installed (idempiere-prerequisites.nix)
#   2. Ansible has installed iDempiere to /opt/idempiere-server
#   3. Add this to configuration.nix:
#      imports = [ ./idempiere-prerequisites.nix ./idempiere-service.nix ];
#   4. Run: sudo nixos-rebuild switch
#
# The service will start automatically after rebuild.

{ config, pkgs, lib, ... }:

let
  idempiere = {
    user = "idempiere";
    group = "idempiere";
    installDir = "/opt/idempiere-server";
  };

in {
  #############################################################################
  # iDempiere systemd service
  # Note: Firewall ports handled by idempiere-nginx.nix (nginx on 80/443)
  #       Jetty (8080/8443) only accessible on localhost
  #############################################################################
  systemd.services.idempiere = {
    description = "iDempiere ERP Server";
    after = [ "network.target" "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      JAVA_HOME = "${pkgs.openjdk17}";
      IDEMPIERE_HOME = idempiere.installDir;
    };

    serviceConfig = {
      Type = "simple";
      User = idempiere.user;
      Group = idempiere.group;
      WorkingDirectory = idempiere.installDir;

      # iDempiere start/stop scripts
      ExecStart = "${idempiere.installDir}/idempiere-server.sh";
      ExecStop = "/bin/kill -SIGTERM $MAINPID";

      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStartSec = "300";
      TimeoutStopSec = "60";

      # Security hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [
        idempiere.installDir
        "/var/log/idempiere"
        "/tmp"
        # Storage provider directories for attachments, archives, images, DMS
        "/opt/idempiere-doc-attachment"
        "/opt/idempiere-doc-archive"
        "/opt/idempiere-doc-image"
        "/opt/idempiere-doc-dms-content"
        "/opt/idempiere-doc-dms-thumbnail"
      ];
      PrivateTmp = true;
    };
  };
}
