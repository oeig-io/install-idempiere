# iDempiere on NixOS

Simple iDempiere ERP installation using NixOS for system configuration and Ansible for orchestration.

Based on the official guide: https://wiki.idempiere.org/en/Installing_iDempiere

## Quick Start: Create Test Instance with Incus

```bash
# Create NixOS container with nesting enabled
incus launch images:nixos/25.11 id-01 \
  -c security.nesting=true \
  -c limits.memory=4GiB \
  -c limits.cpu=2 \
  -d root,size=20GiB

# Copy configuration files
incus file push idempiere-prerequisites.nix id-01/etc/nixos/
incus file push idempiere-service.nix id-01/etc/nixos/
incus file push -r ansible id-01/root/

# Add prerequisites import to configuration.nix
incus exec id-01 -- sed -i 's|./incus.nix|./incus.nix\n    ./idempiere-prerequisites.nix|' /etc/nixos/configuration.nix

# Rebuild NixOS (takes 1-2 minutes on first run)
# NOTE FOR CLAUDE: Use run_in_background=true for this command to preserve context
incus exec id-01 -- sudo nixos-rebuild switch

# Edit passwords before running Ansible!
incus exec id-01 -- nano /root/ansible/vars/idempiere.yml

# Run Ansible playbook (downloads ~500MB, takes several minutes)
incus exec id-01 -- bash -c "cd /root/ansible && ansible-playbook -i inventory.ini idempiere-install.yml -e 'import_database=true' --connection=local"

# Add service import and rebuild to enable systemd service
incus exec id-01 -- sed -i 's|./idempiere-prerequisites.nix|./idempiere-prerequisites.nix\n    ./idempiere-service.nix|' /etc/nixos/configuration.nix
incus exec id-01 -- sudo nixos-rebuild switch

# Check service status
incus exec id-01 -- systemctl status idempiere
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              NixOS                                       │
│                                                                          │
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
│                                 │                                        │
│                                 ▼                                        │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  Ansible (idempiere-install.yml)                                  │  │
│  │  - Download iDempiere 12 from SourceForge                         │  │
│  │  - Extract and install to /opt/idempiere-server                   │  │
│  │  - Configure idempiereEnv.properties via lineinfile (sed-style)   │  │
│  │  - Run silent-setup-alt.sh                                        │  │
│  │  - Import database (RUN_ImportIdempiere.sh)                       │  │
│  │  - Sync database (RUN_SyncDB.sh)                                  │  │
│  │  - Sign database (sign-database-build-alt.sh)                     │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                 │                                        │
│                                 ▼                                        │
│  Phase 2: idempiere-service.nix                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  - systemd service definition                                     │  │
│  │  - Service starts automatically                                   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Files

```
.
├── idempiere-prerequisites.nix      # Phase 1: System prerequisites
├── idempiere-service.nix            # Phase 2: systemd service (add after Ansible)
├── ansible/
│   ├── idempiere-install.yml        # Main playbook
│   ├── inventory.ini                # Ansible inventory
│   └── vars/
│       └── idempiere.yml            # Variables (change passwords!)
└── README.md
```

## Installation Approach

The playbook uses a sed-style configuration approach (learned from studying the official Debian installer's init.d script):

1. Downloads iDempiere `.zip` from SourceForge
2. Extracts to `/opt/idempiere-server`
3. Copies `idempiereEnvTemplate.properties` → `idempiereEnv.properties`
4. Configures properties using Ansible's `lineinfile` module (sed-style)
5. Runs `silent-setup-alt.sh` to generate keystore and Jetty configs
6. Imports the seed database and applies migrations

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

3. **Database role creation** - The `adempiere` role must be created as SUPERUSER before running `RUN_ImportIdempiere.sh`:
   ```sql
   CREATE ROLE adempiere SUPERUSER LOGIN PASSWORD 'password';
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
# Edit passwords first!
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
