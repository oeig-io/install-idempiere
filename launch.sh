#!/usr/bin/env bash
# iDempiere: Container Launch Script
#
# Usage:
#   ./launch.sh <container-name> [--no-install]
#
# Arguments:
#   container-name  Required. The incus container to create (e.g., id-47)
#
# Options:
#   --no-install    Stop after pushing repo (before install.sh). Useful for
#                   manual install with special flags like IDEMPIERE_REMOTE_ACCESS=true
#
# This script creates a fresh iDempiere container:
#   1. Creates NixOS container with incus
#   2. Adds proxy port forward (90xx where xx = container number)
#   3. Pre-seeds iDempiere download (if available at /opt/idempiere-seed/)
#   4. Pushes this repo to /opt/idempiere-install/
#   5. Runs install.sh (unless --no-install)
#   6. Waits for iDempiere to be ready
#
# Prerequisites:
#   - incus installed and configured
#   - /opt/idempiere-seed/ with iDempiere zip (optional, speeds up install)
#
# Examples:
#   ./launch.sh id-47
#   ./launch.sh id-47 --no-install   # Then: incus exec id-47 -- env IDEMPIERE_REMOTE_ACCESS=true /opt/idempiere-install/install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_DIR="/opt/idempiere-seed"
SEED_FILE="idempiereServer12Daily.gtk.linux.x86_64.zip"

# Parse arguments
if [[ $# -lt 1 || "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: $0 <container-name> [--no-install]"
    echo ""
    echo "Options:"
    echo "  --no-install  Stop before install.sh (for manual install with flags)"
    echo ""
    echo "Examples:"
    echo "  $0 id-47"
    echo "  $0 id-47 --no-install"
    exit 0
fi

CONTAINER="$1"
NO_INSTALL=false
if [[ "${2:-}" == "--no-install" ]]; then
    NO_INSTALL=true
fi

# Derive port from container name (id-47 → 9047)
CONTAINER_NUM="${CONTAINER##id-}"
if [[ ! "$CONTAINER_NUM" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Container name must be in format id-XX (e.g., id-47)"
    exit 1
fi
PROXY_PORT="90${CONTAINER_NUM}"

echo "=== iDempiere Container Launch ==="
echo ""
echo "Container: $CONTAINER"
echo "Proxy port: $PROXY_PORT (https://<host>:$PROXY_PORT/webui/)"
echo ""

# Check if container already exists
if incus info "$CONTAINER" &>/dev/null; then
    echo "ERROR: Container '$CONTAINER' already exists"
    echo "       To recreate, first run: incus delete $CONTAINER --force"
    exit 1
fi

# Step 1: Create container
echo ">>> Step 1: Creating NixOS container..."
incus launch images:nixos/25.11 "$CONTAINER" \
    -c security.nesting=true \
    -c limits.memory=4GiB \
    -c limits.cpu=2 \
    -d root,size=20GiB
echo "    Container created."
echo ""

# Step 2: Add proxy port forward
echo ">>> Step 2: Adding proxy port forward..."
sleep 2  # Brief pause to ensure container is ready
incus config device add "$CONTAINER" myproxy proxy \
    listen=tcp:0.0.0.0:"$PROXY_PORT" \
    connect=tcp:127.0.0.1:443
echo "    Proxy configured on port $PROXY_PORT"
echo ""

# Step 3: Pre-seed iDempiere download (if available)
echo ">>> Step 3: Pre-seeding iDempiere download..."
if [[ -f "$SEED_DIR/$SEED_FILE" ]]; then
    incus exec "$CONTAINER" -- mkdir -p /tmp/idempiere-seed
    incus file push "$SEED_DIR/$SEED_FILE" "$CONTAINER/tmp/idempiere-seed/"
    echo "    Pre-seeded from $SEED_DIR/$SEED_FILE"
else
    echo "    No seed file found at $SEED_DIR/$SEED_FILE"
    echo "    Install will download from SourceForge (slower)"
fi
echo ""

# Step 4: Push repo
echo ">>> Step 4: Pushing install repo..."
incus exec "$CONTAINER" -- mkdir -p /opt/idempiere-install
# Must push from within the repo directory to avoid nesting
(cd "$SCRIPT_DIR" && incus file push -r . "$CONTAINER/opt/idempiere-install/")
echo "    Repo pushed to /opt/idempiere-install/"
echo ""

# Step 5: Run installer (unless --no-install)
if [[ "$NO_INSTALL" == true ]]; then
    echo ">>> Step 5: Skipped (--no-install)"
    echo ""
    echo "=== Container Ready for Manual Install ==="
    echo ""
    echo "To install with default settings:"
    echo "  incus exec $CONTAINER -- /opt/idempiere-install/install.sh"
    echo ""
    echo "To install with remote database access:"
    echo "  incus exec $CONTAINER -- env IDEMPIERE_REMOTE_ACCESS=true /opt/idempiere-install/install.sh"
    echo ""
    exit 0
fi

echo ">>> Step 5: Running iDempiere installation..."
echo "    This may take 10-15 minutes..."
incus exec "$CONTAINER" -- /opt/idempiere-install/install.sh
echo "    Installation complete."
echo ""

# Step 6: Wait for iDempiere to be ready
echo ">>> Step 6: Waiting for iDempiere to be ready..."
for i in {1..90}; do
    status=$(incus exec "$CONTAINER" -- curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/v1/auth/tokens 2>/dev/null || echo "000")
    if [[ "$status" == "405" ]]; then
        echo "    iDempiere is ready! (attempt $i)"
        break
    fi
    if [[ $i -eq 90 ]]; then
        echo "    ERROR: Timeout waiting for iDempiere after 90 attempts"
        exit 1
    fi
    echo "    Attempt $i: HTTP $status (waiting...)"
    sleep 5
done
echo ""

echo "=== Container Launch Complete ==="
echo ""
echo "Access iDempiere:"
echo "  Web UI:   https://<host>:$PROXY_PORT/webui/"
echo "  REST API: https://<host>:$PROXY_PORT/api/v1/"
echo ""
echo "Next steps (from idempiere-golive-deploy/):"
echo "  ./deploy.sh $CONTAINER    # Apply go-live configuration"
echo "  ./test.sh $CONTAINER      # Run test data scripts"
