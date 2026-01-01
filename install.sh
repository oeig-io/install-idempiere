#!/usr/bin/env bash
# install.sh - Third-party contract entry point for iDempiere
#
# Self-contained installer that wraps existing installation steps.
# Executes three phases: prerequisites → ansible → service
#
# Usage: ./install.sh
#
# Environment Variables:
#   VILARA_REMOTE_ACCESS=true  Enable cross-container database access (default: false)
#
# Assumes:
#   - NixOS base system
#   - Script directory contains idempiere-prerequisites.nix, idempiere-service.nix, ansible/
#
# Design Principles:
#   - This script exists solely to facilitate coordination
#   - Minimal logic, no feature-specific conditionals
#   - Environment variables pass through to Ansible as extra vars
#   - Conditional logic belongs in Ansible playbooks, not here
#   - See: planning/idempiere-vilara-connector.md

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== iDempiere Installation ==="
echo "Script directory: $SCRIPT_DIR"

# Phase 1: NixOS Prerequisites
echo ""
echo "=== Phase 1: NixOS Prerequisites ==="
if grep -q "idempiere-prerequisites.nix" /etc/nixos/configuration.nix; then
    echo "Prerequisites already in configuration.nix, skipping..."
else
    sed -i 's|./incus.nix|./incus.nix\n    '"$SCRIPT_DIR"'/idempiere-prerequisites.nix|' /etc/nixos/configuration.nix
fi
sudo nixos-rebuild switch

# Phase 2: Ansible Installation
# Environment variables are passed through as Ansible extra vars.
# Ansible playbook contains all conditional logic for optional features.
echo ""
echo "=== Phase 2: Ansible Installation ==="
cd "$SCRIPT_DIR/ansible"
ansible-playbook -i inventory.ini idempiere-install.yml \
    -e "import_database=true" \
    -e "vilara_remote_access=${VILARA_REMOTE_ACCESS:-false}" \
    --connection=local

# Phase 3: NixOS Service
echo ""
echo "=== Phase 3: NixOS Service ==="
if grep -q "idempiere-service.nix" /etc/nixos/configuration.nix; then
    echo "Service already in configuration.nix, skipping..."
else
    sed -i 's|idempiere-prerequisites.nix|idempiere-prerequisites.nix\n    '"$SCRIPT_DIR"'/idempiere-service.nix|' /etc/nixos/configuration.nix
fi
sudo nixos-rebuild switch

echo ""
echo "=== iDempiere Installation Complete ==="
echo "Service status: systemctl status idempiere"
echo "Web UI: http://localhost:8080/webui/"
echo "REST API: http://localhost:8080/api/v1/"
