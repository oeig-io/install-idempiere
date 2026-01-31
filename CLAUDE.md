# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an iDempiere ERP deployment automation framework for NixOS. It combines NixOS declarative configuration with Ansible orchestration to deploy iDempiere 12 with PostgreSQL 17 and the REST API plugin.

## Architecture

The installation follows a 4-phase approach:

1. **Phase 1 - NixOS Prerequisites** (`idempiere-prerequisites.nix`): System packages, PostgreSQL, idempiere user, directories
2. **Phase 2 - Ansible Orchestration** (`ansible/idempiere-install.yml`): Download iDempiere, configure, import database, install REST API plugin
3. **Phase 3 - NixOS Service** (`idempiere-service.nix`): systemd service definition (Jetty on localhost:8080/8443)
4. **Phase 4 - NixOS nginx** (`idempiere-nginx.nix`): nginx reverse proxy on ports 80/443 with self-signed SSL

Key design decisions:
- Uses sed-based configuration (from Debian installer) instead of Java properties parsing
- `.pgpass` file is the single source of truth for database credentials (password auto-generated on first boot, persists across rebuilds)
- Includes NixOS-specific workarounds (e.g., `/bin/bash` symlink creation)

## Key Commands

```bash
# Full installation (runs all 4 phases)
./install.sh

# Phase 1: Apply NixOS prerequisites
sudo nixos-rebuild switch

# Phase 2: Run Ansible deployment
cd /root/ansible
ansible-playbook -i inventory.ini idempiere-install.yml -e 'import_database=true' --connection=local

# Service management
systemctl status idempiere
systemctl status nginx
systemctl start idempiere
systemctl stop idempiere
journalctl -u idempiere -f

# Database access (uses ~/.pgpass credentials)
psqli
psqli -c "SELECT * FROM ad_system"

# REST API token (default credentials: GardenAdmin/GardenAdmin)
curl -k -X POST https://localhost/api/v1/auth/tokens \
  -H "Content-Type: application/json" \
  -d '{"userName":"GardenAdmin","password":"GardenAdmin"}'
```

## File Structure

- `install.sh` - Automated installation (runs inside container)
- `idempiere-prerequisites.nix` - NixOS module for system dependencies and PostgreSQL
- `idempiere-service.nix` - NixOS systemd service definition
- `idempiere-nginx.nix` - NixOS nginx reverse proxy (ports 80/443)
- `ansible/idempiere-install.yml` - Main Ansible playbook
- `ansible/vars/idempiere.yml` - Deployment variables and passwords

## NixOS-Specific Notes

- `/bin/bash` doesn't exist by default - fixed with activation script in prerequisites
- PostgreSQL `listen_addresses` requires `lib.mkForce` to override
- `sudo nixos-rebuild switch` required even when running as root
- Python 3 is installed for local Ansible execution

## iDempiere Configuration

- Installation directory: `/opt/idempiere-server`
- External ports: 80 (HTTP → redirects to HTTPS), 443 (HTTPS via nginx)
- Internal ports: Jetty on localhost:8080/8443 (not exposed externally)
- Database: PostgreSQL 17 on localhost:5432
- Database role must be SUPERUSER for JDBC connection
- Script name is `silent-setup-alt.sh` (not `silentsetup-alt.sh`)

## Container Deployment

Container creation is handled by the `container-management` module:

```bash
# From container-management directory:
./launch.sh configs/idempiere.conf id-xx              # Create and install
./launch.sh configs/idempiere.conf id-xx --no-install # Create only (for manual install with flags)
```

See `README.md` for details and running commands inside the container.

## Reference Documentation

- iDempiere Wiki: https://wiki.idempiere.org/
- REST API Docs: https://bxservice.github.io/idempiere-rest-docs/
