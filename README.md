# iDempiere on NixOS

Simple iDempiere ERP installation using NixOS for system configuration and Ansible for orchestration. Includes the [REST API plugin](https://github.com/bxservice/idempiere-rest) by default (see [REST API docs](https://bxservice.github.io/idempiere-rest-docs/)).

Based on the official guide: https://wiki.idempiere.org/en/Installing_iDempiere

## Quick Start

```bash
# Clone the repository
git clone <repository-url>

# Create NixOS container
incus launch images:nixos/25.11 id-xx \
  -c security.nesting=true \
  -c limits.memory=4GiB \
  -c limits.cpu=2 \
  -d root,size=20GiB

# Add proxy port forward (90xx where xx = container number, e.g., id-05 → 9005)
# Note: this command must be run separately from the above launch command. It hangs otherwise.
incus config device add id-xx myproxy proxy listen=tcp:0.0.0.0:90xx connect=tcp:127.0.0.1:8080

# Push repo and run installer (IMPORTANT: must run from within the repo directory)
incus exec id-xx -- mkdir -p /opt/idempiere-install
cd idempiere-third-party-deploy
incus file push -r . id-xx/opt/idempiere-install/
incus exec id-xx -- /opt/idempiere-install/install.sh

# If pushing from outside the repo (e.g., from parent directory), the structure will be wrong:
#   WRONG:  incus file push -r ./idempiere-third-party-deploy/. id-xx/opt/idempiere-install/
#   This creates: /opt/idempiere-install/idempiere-third-party-deploy/install.sh (nested!)
#   CORRECT: cd idempiere-third-party-deploy && incus file push -r . id-xx/opt/idempiere-install/

# Note: the install can take up to 15 minutes.

# Access iDempiere (via proxy port on host)
# Web UI: http://<host-ip>:90xx/webui/
# REST API: http://<host-ip>:90xx/api/v1/
```

### With iDempiere Remote Access

For container deployments that need cross-container database access:

```bash
# Enable remote access during installation
incus exec id-xx -- env IDEMPIERE_REMOTE_ACCESS=true /opt/idempiere-install/install.sh
```

### Pre-seeding the iDempiere Download

If SourceForge is slow or unavailable, you can pre-copy the iDempiere zip file before running `install.sh`. The installer checks `/tmp/idempiere-seed/` for a pre-seeded file and uses it instead of downloading.

**Option A: From host cache (recommended)**

The host maintains a cached copy at `/opt/idempiere-seed/`:

```bash
# After pushing the repo but BEFORE running install.sh:
incus exec id-xx -- mkdir -p /tmp/idempiere-seed
incus file push /opt/idempiere-seed/idempiereServer12Daily.gtk.linux.x86_64.zip id-xx/tmp/idempiere-seed/

# Now run the installer - it will use the pre-seeded file instead of downloading
incus exec id-xx -- /opt/idempiere-install/install.sh
```

**Option B: From an existing container**

```bash
# Copy from an existing container (e.g., id-36) to the new container's seed directory
incus exec id-xx -- mkdir -p /tmp/idempiere-seed
incus file pull id-36/home/idempiere/downloads/idempiereServer12Daily.gtk.linux.x86_64.zip /tmp/
incus file push /tmp/idempiereServer12Daily.gtk.linux.x86_64.zip id-xx/tmp/idempiere-seed/

# Now run the installer
incus exec id-xx -- /opt/idempiere-install/install.sh
```

This additionally:
- Opens PostgreSQL port 5432 to the container network
- Creates `idempiere_readonly` and `idempiere_readwrite` database users
- Configures pg_hba.conf for container network access (10.0.0.0/8)

## Running Commands in the Container

+Commands like `psqli` **must** be run inside the container as the `idempiere` user (which has the `.pgpass` credentials configured). They will not work from the host or as root.

```bash
# Interactive shell as idempiere user
incus exec id-xx -- su --login idempiere

# Run a single command as idempiere user
incus exec id-xx -- su --login idempiere -c "psqli"
incus exec id-xx -- su - idempiere -c "psqli -c \"SELECT c_bpartner_id, value, name FROM c_bpartner ORDER BY name\""

# Check service status
incus exec id-xx -- systemctl status idempiere

# View logs
incus exec id-xx -- journalctl -u idempiere -f
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              NixOS                                      │
│                                                                         │
│  Phase 1: idempiere-prerequisites.nix                                   │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  - OpenJDK 17                                                     │  │
│  │  - PostgreSQL 17                                                  │  │
│  │  - Python 3 (for Ansible)                                         │  │
│  │  - unzip                                                          │  │
│  │  - /bin/bash symlink (NixOS compatibility)                        │  │
│  │  - idempiere user/group                                           │  │
│  │  - /opt/idempiere-server directory                                │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                 │                                       │
│                                 ▼                                       │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  Ansible (idempiere-install.yml)                                  │  │
│  │  - Download iDempiere 12 from SourceForge                         │  │
│  │  - Extract and install to /opt/idempiere-server                   │  │
│  │  - Configure idempiereEnv.properties via lineinfile (sed-style)   │  │
│  │  - Run silent-setup-alt.sh                                        │  │
│  │  - Import database (RUN_ImportIdempiere.sh)                       │  │
│  │  - Sync database (RUN_SyncDB.sh)                                  │  │
│  │  - Sign database (sign-database-build-alt.sh)                     │  │
│  │  - Install REST API plugin (update-prd.sh)                        │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                 │                                       │
│                                 ▼                                       │
│  Phase 2: idempiere-service.nix                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  - systemd service definition                                     │  │
│  │  - Service starts automatically                                   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Files

```
.
├── install.sh                       # Automated installer (runs all phases)
├── idempiere-prerequisites.nix      # Phase 1: System prerequisites
├── idempiere-service.nix            # Phase 2: systemd service (add after Ansible)
├── idempiere-remote-access.nix      # Generated when IDEMPIERE_REMOTE_ACCESS=true
├── ansible/
│   ├── idempiere-install.yml        # Main playbook
│   ├── inventory.ini                # Ansible inventory
│   ├── templates/
│   │   └── idempiere-remote-access.nix.j2  # Remote access NixOS overlay
│   └── vars/
│       └── idempiere.yml            # Variables (DB password auto-generated)
└── README.md
```

## iDempiere Integration Users

The installer creates two additional database users for cross-container access:

| User | Purpose | Permissions |
|------|---------|-------------|
| `idempiere_readonly` | Read-only queries | SELECT on adempiere schema |
| `idempiere_readwrite` | Read-write operations | SELECT, INSERT, UPDATE, DELETE on adempiere schema |

Credentials are stored in `/home/idempiere/.pgpass`:

```bash
# View all database credentials
incus exec id-xx -- su - idempiere -c "cat ~/.pgpass"

# Example output:
# localhost:5432:idempiere:adempiere:randompass1
# localhost:5432:idempiere:idempiere_readonly:randompass2
# localhost:5432:idempiere:idempiere_readwrite:randompass3
```

Note: Remote containers needing access should have their `.pgpass` configured with the iDempiere container IP.

### Verify Remote Access

When `IDEMPIERE_REMOTE_ACCESS=true`:

```bash
# Check PostgreSQL is listening on all interfaces (0.0.0.0)
incus exec id-xx -- ss -tlnp | grep 5432

# Check firewall allows port 5432
incus exec id-xx -- iptables -L -n | grep 5432

# Test connection from another container on the same network
psql -h <idempiere-container-ip> -U idempiere_readonly -d idempiere -c "SELECT count(*) FROM ad_table"
```

## Installation Approach

The playbook uses a sed-style configuration approach (learned from studying the official Debian installer's init.d script):

1. Downloads iDempiere `.zip` from SourceForge
2. Extracts to `/opt/idempiere-server`
3. Copies `idempiereEnvTemplate.properties` → `idempiereEnv.properties`
4. Configures properties using Ansible's `lineinfile` module (sed-style)
5. Runs `silent-setup-alt.sh` to generate keystore and Jetty configs
6. Imports the seed database and applies migrations
7. Installs the REST API plugin via `update-prd.sh`

## REST API Examples

After installation, the REST API is available at `http://<server>:8080/api/v1/`. See the [full documentation](https://bxservice.github.io/idempiere-rest-docs/) for details.

### Checking REST API Readiness

**Important:** The REST API is not immediately available when the iDempiere service starts. There is a startup delay (typically 15-60 seconds) while OSGi bundles initialize and 2Pack migrations run.

**The problem:** Using `curl` to check readiness causes connection timeouts during startup, making it unreliable as a health check.

**Recommended approach:** Check the systemd journal for the final REST API 2Pack migration completion:

```bash
# Wait for REST API to be ready (check journal for final migration)
until journalctl -u idempiere --no-pager | grep -q "2Pack_1.0.18.zip installed"; do
  echo "Waiting for REST API initialization..."
  sleep 5
done
echo "REST API ready"
```

**Note:** This approach is not perfect - the version number (1.0.18) may change with REST API plugin updates, and there may be additional initialization after this log message. However, it is more reliable than curl-based checks which simply timeout during startup.

**Startup sequence for reference:**
1. `systemd` reports service "Started" (not yet ready)
2. `com.trekglobal.idempiere.rest.api ... ready.` - OSGi bundle loaded (not yet ready)
3. `LoggedSessionListener.contextInitialized` - Web context initialized
4. `2Pack_1.0.18.zip installed` - Final REST API migration (API should be ready)

### Authenticate and Get Token

```bash
# Get authentication token (valid for 1 hour)
curl -X POST http://localhost:8080/api/v1/auth/tokens \
  -H "Content-Type: application/json" \
  -d '{"userName":"GardenAdmin","password":"GardenAdmin"}'

# Response:
# {"clients":[{"id":11,"name":"GardenWorld"}],"token":"eyJraWQiOi..."}
```

### Select Client and Get Session Token

```bash
# Use the token from above to select a client
TOKEN="eyJraWQiOi..."

curl -X PUT http://localhost:8080/api/v1/auth/tokens \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"clientId":11,"roleId":102,"organizationId":0,"warehouseId":0}'

# Response includes a new token for API calls
```

### Query Business Partners

```bash
curl -X GET "http://localhost:8080/api/v1/models/c_bpartner" \
  -H "Authorization: Bearer $TOKEN"
```

### Query Products

```bash
curl -X GET "http://localhost:8080/api/v1/models/m_product" \
  -H "Authorization: Bearer $TOKEN"
```

### Query with Filters

```bash
# Get active products with specific columns
curl -X GET "http://localhost:8080/api/v1/models/m_product?\$filter=IsActive eq true&\$select=Name,Value,Description" \
  -H "Authorization: Bearer $TOKEN"
```

### Create a Business Partner

```bash
curl -X POST http://localhost:8080/api/v1/models/c_bpartner \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "Name": "Test Partner",
    "Value": "TEST001",
    "IsCustomer": true,
    "IsVendor": false
  }'
```

## Known Issues & Lessons Learned

### NixOS-Specific Issues

1. **`/bin/bash` doesn't exist** - iDempiere scripts use `#!/bin/bash` shebang. Fixed by adding activation script:
   ```nix
   system.activationScripts.binbash = ''
     mkdir -p /bin
     ln -sf ${pkgs.bash}/bin/bash /bin/bash
   '';
   ```

2. **Python required for Ansible** - Must explicitly add `python3` to system packages for Ansible to work locally.

3. **PostgreSQL `listen_addresses` conflict** - When `enableTCPIP = true`, NixOS sets `listen_addresses = "*"`. Use `lib.mkForce` to override:
   ```nix
   settings = {
     listen_addresses = lib.mkForce "localhost";
   };
   ```

4. **Always use `sudo nixos-rebuild`** - Even when running as root, `sudo` is required to set up the proper NIX_PATH environment.

### iDempiere Installation Issues

1. **Script names** - The correct script names from the Debian installer:
   - `silent-setup-alt.sh` (not `silentsetup-alt.sh`)
   - `sign-database-build-alt.sh` (not `sign-database-alt.sh`)

2. **ADEMPIERE_DB_SYSTEM password required** - Unlike Debian installer which can use Unix sockets via `su postgres`, JDBC requires a password for TCP connections.

3. **Database role creation** - The `adempiere` role must be created as SUPERUSER before running `RUN_ImportIdempiere.sh`. The password is auto-generated and stored in `/home/idempiere/.pgpass`:
   ```sql
   -- Read password from: cat /home/idempiere/.pgpass | cut -d: -f5
   CREATE ROLE adempiere SUPERUSER LOGIN PASSWORD '<auto-generated>';
   ```

## Installation Steps

### Phase 1: Configure NixOS Prerequisites

```nix
# /etc/nixos/configuration.nix
imports = [
  ./hardware-configuration.nix
  ./idempiere-prerequisites.nix
];
```

```bash
sudo nixos-rebuild switch
```

### Phase 2: Run Ansible Installation

```bash
# Review settings (DB password is auto-generated in ~/.pgpass)
nano ansible/vars/idempiere.yml

cd ansible
ansible-playbook -i inventory.ini idempiere-install.yml -e "import_database=true" --connection=local
```

### Phase 3: Enable the Service

```bash
# Add service import to configuration.nix
sed -i 's|./idempiere-prerequisites.nix|./idempiere-prerequisites.nix\n    ./idempiere-service.nix|' /etc/nixos/configuration.nix

sudo nixos-rebuild switch
```

## Debian Installer Reference

The Ansible playbook's configuration approach is based on the official Debian installer's `configure_perform()` function in `/etc/init.d/idempiere`:

```bash
# Key steps from configure_perform():
cp ${IDEMPIERE_HOME}/idempiereEnvTemplate.properties ${IDEMPIERE_HOME}/idempiereEnv.properties
sed -i "s:^IDEMPIERE_HOME=.*:IDEMPIERE_HOME=${IDEMPIERE_HOME}:" ${IDEMPIERE_HOME}/idempiereEnv.properties
sed -i "s:^JAVA_HOME=.*:JAVA_HOME=${JAVA_HOME}:" ${IDEMPIERE_HOME}/idempiereEnv.properties
# ... etc for each variable
```

This sed-based approach bypasses the Java silent installer's property file parsing and is more reliable.

## References

- [iDempiere Wiki](https://wiki.idempiere.org/)
- [Install Prerequisites](https://wiki.idempiere.org/en/Install_Prerequisites)
- [Installing from Installers](https://wiki.idempiere.org/en/Installing_from_Installers)
- [Debian Installer](https://wiki.idempiere.org/en/IDempiere_Debian_Installer)
- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [SourceForge Downloads](https://sourceforge.net/projects/idempiere/files/v12/daily-server/)
- [REST API Plugin](https://github.com/bxservice/idempiere-rest)
- [REST API Documentation](https://bxservice.github.io/idempiere-rest-docs/)
