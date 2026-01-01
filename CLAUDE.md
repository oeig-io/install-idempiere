# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an iDempiere ERP deployment automation framework for NixOS. It combines NixOS declarative configuration with Ansible orchestration to deploy iDempiere 12 with PostgreSQL 17 and the REST API plugin.

## Architecture

The installation follows a 3-phase approach:

1. **Phase 1 - NixOS Prerequisites** (`idempiere-prerequisites.nix`): System packages, PostgreSQL, idempiere user, directories
2. **Phase 2 - Ansible Orchestration** (`ansible/idempiere-install.yml`): Download iDempiere, configure, import database, install REST API plugin
3. **Phase 3 - NixOS Service** (`idempiere-service.nix`): systemd service definition with auto-start and firewall rules

Key design decisions:
- Uses sed-based configuration (from Debian installer) instead of Java properties parsing
- `.pgpass` file is the single source of truth for database credentials (password auto-generated on first boot, persists across rebuilds)
- Includes NixOS-specific workarounds (e.g., `/bin/bash` symlink creation)

## Key Commands

```bash
# Full installation (runs all 3 phases)
./install.sh

# Phase 1: Apply NixOS prerequisites
sudo nixos-rebuild switch

# Phase 2: Run Ansible deployment
cd /root/ansible
ansible-playbook -i inventory.ini idempiere-install.yml -e 'import_database=true' --connection=local

# Service management
systemctl status idempiere
systemctl start idempiere
systemctl stop idempiere
journalctl -u idempiere -f

# Database access (uses ~/.pgpass credentials)
psqli
psqli -c "SELECT * FROM ad_system"

# REST API token (default credentials: GardenAdmin/GardenAdmin)
curl -X POST http://localhost:8080/api/v1/auth/tokens \
  -H "Content-Type: application/json" \
  -d '{"userName":"GardenAdmin","password":"GardenAdmin"}'
```

## File Structure

- `idempiere-prerequisites.nix` - NixOS module for system dependencies and PostgreSQL
- `idempiere-service.nix` - NixOS systemd service definition
- `install.sh` - Automated installation entry point
- `ansible/idempiere-install.yml` - Main Ansible playbook (330 lines)
- `ansible/vars/idempiere.yml` - Deployment variables and passwords
- `ansible/inventory.ini` - Ansible host configuration

## NixOS-Specific Notes

- `/bin/bash` doesn't exist by default - fixed with activation script in prerequisites
- PostgreSQL `listen_addresses` requires `lib.mkForce` to override
- `sudo nixos-rebuild switch` required even when running as root
- Python 3 is installed for local Ansible execution

## iDempiere Configuration

- Installation directory: `/opt/idempiere-server`
- Ports: 8080 (HTTP), 8443 (HTTPS)
- Database: PostgreSQL 17 on localhost:5432
- Database role must be SUPERUSER for JDBC connection
- Script name is `silent-setup-alt.sh` (not `silentsetup-alt.sh`)

## Container Access

See `README.md` for container deployment (incus), installation steps, and running commands as the `idempiere` user.

## Reference Documentation

- iDempiere Wiki: https://wiki.idempiere.org/
- REST API Docs: https://bxservice.github.io/idempiere-rest-docs/
