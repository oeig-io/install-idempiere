# idempiere-nginx.nix
# NixOS module for nginx reverse proxy in front of iDempiere
#
# This module configures nginx to:
#   - Listen on ports 80 (HTTP) and 443 (HTTPS)
#   - Proxy requests to iDempiere (Jetty) on localhost:8443
#   - Handle SSL termination
#   - Apply response rewriting for path-based routing (optional)
#
# Workflow:
#   1. Prerequisites and service installed
#   2. Add to configuration.nix:
#      imports = [ ./idempiere-prerequisites.nix ./idempiere-service.nix ./idempiere-nginx.nix ];
#   3. Run: sudo nixos-rebuild switch
#
# For path-based routing (e.g., /id-04/):
#   - Set pathPrefix below to your container name
#   - External load balancer routes /id-04/* to this container

{ config, pkgs, lib, ... }:

let
  # Configuration - adjust these for your deployment
  nginx = {
    # Set to container name for path-based routing (e.g., "id-04")
    # Leave empty "" for root-level access
    pathPrefix = "";

    # SSL certificate paths (self-signed generated below if not exists)
    sslCertificate = "/etc/nginx/ssl/nginx.crt";
    sslCertificateKey = "/etc/nginx/ssl/nginx.key";
  };

  # iDempiere backend (Jetty)
  backend = {
    host = "127.0.0.1";
    port = 8443;
  };

  # Build location path based on prefix
  locationPath = if nginx.pathPrefix == "" then "/" else "/${nginx.pathPrefix}/";

  # Build the extraConfig for sub_filter rules (only needed with path prefix)
  subFilterConfig = if nginx.pathPrefix == "" then "" else ''
    # Fix cookie paths
    proxy_cookie_path /webui /${nginx.pathPrefix}/webui;
    proxy_cookie_path / /${nginx.pathPrefix}/;

    # Rewrite absolute paths in responses
    sub_filter_once off;
    sub_filter_types text/html text/css text/plain application/javascript text/javascript application/json;

    # Double-quoted paths
    sub_filter 'href="/' 'href="/${nginx.pathPrefix}/';
    sub_filter 'src="/' 'src="/${nginx.pathPrefix}/';
    sub_filter 'action="/' 'action="/${nginx.pathPrefix}/';

    # Single-quoted paths (JS) - only /webui since /zkau is under /webui
    sub_filter "'/webui" "'/${nginx.pathPrefix}/webui";

    # Hex-encoded paths (ZK framework) - only /webui to avoid double rewrite
    sub_filter '\x2Fwebui' '\x2F${nginx.pathPrefix}\x2Fwebui';

    # JSON escaped paths (AJAX responses) - only /webui
    sub_filter '\/webui' '\/${nginx.pathPrefix}\/webui';

    # CSS url() paths
    sub_filter 'url(/' 'url(/${nginx.pathPrefix}/';
  '';

in {
  #############################################################################
  # SSL Certificate Generation
  # Creates self-signed certificate if it doesn't exist
  # Note: nginx user must be able to read the key file
  #############################################################################
  system.activationScripts.nginxSsl = ''
    SSL_DIR="/etc/nginx/ssl"
    if [ ! -f "$SSL_DIR/nginx.crt" ]; then
      mkdir -p "$SSL_DIR"
      ${pkgs.openssl}/bin/openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "$SSL_DIR/nginx.key" \
        -out "$SSL_DIR/nginx.crt" \
        -subj "/CN=idempiere-container/O=iDempiere/C=US"
      chown nginx:nginx "$SSL_DIR/nginx.key"
      chmod 600 "$SSL_DIR/nginx.key"
      chmod 644 "$SSL_DIR/nginx.crt"
      echo "Generated self-signed SSL certificate in $SSL_DIR"
    fi
  '';

  #############################################################################
  # Firewall - nginx ports (Jetty only accessible on localhost)
  #############################################################################
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  #############################################################################
  # nginx reverse proxy
  #############################################################################
  services.nginx = {
    enable = true;

    # Recommended settings (excluding proxy - we use explicit headers)
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = false;  # Disabled: we use explicit headers from tested template
    recommendedTlsSettings = true;

    # Default server
    virtualHosts."_" = {
      default = true;

      # SSL configuration
      forceSSL = true;
      sslCertificate = nginx.sslCertificate;
      sslCertificateKey = nginx.sslCertificateKey;

      locations.${locationPath} = {
        proxyPass = "https://${backend.host}:${toString backend.port}/";
        proxyWebsockets = true;

        extraConfig = ''
          # Proxy headers (explicit, from tested Jinja2 template)
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header Accept-Encoding "";

          # SSL settings for backend (Jetty uses self-signed cert)
          proxy_ssl_verify off;
          proxy_ssl_server_name on;

          # Timeout settings (90 minutes for long operations)
          proxy_connect_timeout 5400s;
          proxy_read_timeout 5400s;
          proxy_send_timeout 5400s;

          ${subFilterConfig}
        '';
      };
    };
  };
}
