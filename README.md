# NemoClaw Production Deployment on Hetzner CX43

A production-ready, fully automated NemoClaw setup on Hetzner CX43 with infrastructure-as-code, backup/restore, and one-command teardown.

## Overview

This deployment provides:
- **Infrastructure-as-Code**: Docker Compose for reproducible, versioned deployments
- **Automated Setup**: Single command installation with idempotent scripts
- **Persistent Storage**: Backed-up configuration, models, and sandbox states
- **Easy Recovery**: One-command restore from backups
- **Clean Destruction**: Preserve data while removing all services
- **Monitoring**: Optional observability stack

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Hetzner CX43 Instance                     │
│  8 vCPU | 16 GB RAM | 160 GB NVMe | Ubuntu 22.04 LTS       │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  NemoClaw Host (systemd managed)                      │   │
│  │  - OpenShell Gateway                                  │   │
│  │  - nemoclaw CLI                                       │   │
│  ├──────────────────────────────────────────────────────┤   │
│  │  Sandboxed OpenClaw Instances (OpenShell)            │   │
│  │  - Sandbox 1 (my-assistant, etc.)                    │   │
│  │  - Sandbox N (policy-enforced isolation)             │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Supporting Services (Docker Compose)                │   │
│  │  - Ollama (optional local inference)                 │   │
│  │  - Prometheus + Grafana (optional monitoring)        │   │
│  │  - Backup runner (daily automated backups)           │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Persistent Volumes                                   │   │
│  │  - /srv/nemoclaw/config         (NemoClaw state)     │   │
│  │  - /srv/nemoclaw/models         (Local models)       │   │
│  │  - /srv/nemoclaw/backups        (Backup storage)     │   │
│  │  - /srv/nemoclaw/logs           (Logs & events)      │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Provision Hetzner CX43

In **Hetzner Cloud Console**:
1. Click **"Create" → Server**
2. **Image:** Select Ubuntu 22.04 LTS
3. **Type:** Select CX43 (8 vCPU, 16 GB RAM, 160 GB NVMe)
4. **SSH Key:** Select your public key
5. **Location:** Choose nearest to you
6. Click **"Create & Buy now"**

Wait 2-3 minutes for server to boot, then SSH in:

```bash
ssh root@<instance-ip>
```

### 2. Run Foundational Setup

```bash
# Create deployment directory
mkdir -p /root/nemoclaw-deploy
cd /root/nemoclaw-deploy

# Copy .env configuration
cp .env.example .env
nano .env  # Add your NVIDIA_API_KEY (or skip for now)

# Run automated foundational setup
bash scripts/setup.sh

# When prompted: "Run NVIDIA installer? (y/n)"
# Answer: y (or run manually later)
```

**What foundational setup does:**
- Updates system packages
- Creates nemoclaw non-root user
- Installs Docker
- Installs Node.js 20+
- Installs OpenShell via pip3
- Creates persistent storage directories
- Sets up systemd service
- **Delegates to official NVIDIA installer for NemoClaw CLI**

**Setup time:** ~5-10 minutes (depending on internet speed)

### 3. Official NVIDIA NemoClaw Installer

Once foundational setup completes, the official NVIDIA installer will run:

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

This installer:
1. Clones official NemoClaw repository
2. Builds NemoClaw CLI
3. Runs interactive onboarding
4. Creates your first sandbox
5. Asks for NVIDIA API key (free tier available at https://build.nvidia.com/)

**Important:** Before running onboarding, source your `.env` file:

```bash
# Load environment variables
source .env

# Verify API key is set
echo $NVIDIA_API_KEY

# Now run onboarding
nemoclaw onboard
```

If API key is not loaded, onboarding will fail at step [6/7] with "sandbox not found" error.

### 4. Start Using NemoClaw

```bash
# Connect to your sandbox
nemoclaw my-assistant connect

# Inside the sandbox, start chatting
openclaw tui

# Or send messages via CLI
openclaw agent -m "hello"
```

### 5. (Optional) Telegram Bot Integration

Connect NemoClaw to Telegram for easy messaging:

**During Onboarding:**
When the installer asks about policy presets, select **only `telegram`**. Skip all others unless you specifically need them:

```
○ discord     — Not needed
○ docker      — Not needed
○ huggingface — Not needed
○ jira        — Not needed
○ npm         — Not needed
○ outlook     — Not needed
● telegram    — SELECT THIS (for Telegram Bot)
○ pypi        — Not needed
○ slack       — Not needed
```

**Create Telegram Bot:**

1. Open Telegram and start chat with [@BotFather](https://t.me/botfather)
2. Send `/newbot`
3. Follow the prompts to name your bot
4. BotFather gives you a bot token (e.g., `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)

**Configure Bot Token:**

NemoClaw stores credentials in `~/.nemoclaw/credentials.json`. Add your bot token:

```bash
# Create credentials file with both tokens
cat > ~/.nemoclaw/credentials.json << EOF
{
  "TELEGRAM_BOT_TOKEN": "YOUR_BOT_TOKEN_HERE",
  "NVIDIA_API_KEY": "YOUR_NVIDIA_API_KEY_HERE"
}
EOF

# Restrict permissions (important - contains secrets)
chmod 600 ~/.nemoclaw/credentials.json
```

**Start Telegram Services:**

NemoClaw reads credentials from the file but needs the token in the **environment** to start:

```bash
# Export token from credentials file
export TELEGRAM_BOT_TOKEN=$(grep -o '"TELEGRAM_BOT_TOKEN":"[^"]*"' ~/.nemoclaw/credentials.json | cut -d'"' -f4)

# Verify it's set
echo $TELEGRAM_BOT_TOKEN

# Start services
nemoclaw start
```

You should see:
```
telegram-bridge started (PID xxxxx)
  ┌─────────────────────────────────────────────────────┐
  │  NemoClaw Services                                  │
  │  Telegram:    bridge running                        │
  └─────────────────────────────────────────────────────┘
```

**Start Chatting:**

Find your bot in Telegram (search by the name you gave it) and send a message! It will be forwarded to your NemoClaw sandbox.

**Useful Commands:**

```bash
# Check service status
nemoclaw status

# Stop all services
nemoclaw stop

# View diagnostics
nemoclaw debug

# Check credentials were saved
cat ~/.nemoclaw/credentials.json
```

### 6. (Optional) Start Supporting Services

```bash
# Start Ollama, monitoring, backup runner
docker compose --profile full up -d

# Or just backup runner
docker compose up -d backup-runner
```

## Directory Structure

```
nemoclaw-deploy/
├── README.md                          # This file
├── .env.example                       # Environment template
├── .env                               # Your secrets (not in git)
├── docker-compose.yml                 # Supporting services
├── prometheus.yml                     # Monitoring config
├── .gitignore                         # Ignore secrets
│
├── scripts/
│   ├── setup.sh                       # Initial installation
│   ├── backup.sh                      # Create backups
│   ├── restore.sh                     # Restore from backup
│   ├── destroy.sh                     # Clean teardown
│   ├── health-check.sh                # Status verification
│   └── daily-backup.sh                # Cron script
│
├── config/
│   └── nemoclaw-init.sh               # First-run configuration
│
└── docs/
    ├── OPERATIONS.md                  # Day-to-day operations
    ├── BACKUP-RESTORE.md              # Backup procedures
    ├── TROUBLESHOOTING.md             # Common issues
    └── ARCHITECTURE.md                # Technical deep dive
```

## Key Operations

### Backup Everything

```bash
bash scripts/backup.sh
# Creates: /srv/nemoclaw/backups/nemoclaw-backup-YYYY-MM-DD-HH-MM-SS.tar.gz
# Contains: configs, models, sandbox states, logs
# Size: ~varies (models can be large)
```

### Restore from Backup

```bash
# List available backups
ls -lh /srv/nemoclaw/backups/

# Restore specific backup
bash scripts/restore.sh nemoclaw-backup-2025-03-22-14-30-00.tar.gz

# Verifies integrity, stops services, restores files, restarts services
```

### Destroy Instance (Keep Backups)

```bash
# Remove all services, keeps /srv/nemoclaw/backups/
bash scripts/destroy.sh

# Confirms before deletion
# Can reinstall cleanly afterward
```

### Health Check

```bash
bash scripts/health-check.sh

# Output example:
# ──────────────────────────────────────
# NemoClaw Health Status
# ──────────────────────────────────────
# Sandboxes:        1 active
# OpenShell gateway: running
# Supporting services: 2/2 running
# Disk usage:        12% / 160 GB
# Memory:            6.2 GB / 16 GB (38%)
# Backups available: 5 (latest: 2h ago)
# ──────────────────────────────────────
```

## Environment Configuration

Edit `.env` before setup:

```bash
# NVIDIA Inference
NVIDIA_API_KEY="nvapi-..."
INFERENCE_MODEL="nvidia/nemotron-3-super-120b-a12b"

# OpenShell / NemoClaw
NEMOCLAW_HOME="/home/nemoclaw"
SANDBOX_NAME="my-assistant"
SANDBOX_POLICY="strict"  # or 'moderate', 'permissive'

# Local Inference (optional)
OLLAMA_ENABLED="false"  # Set to 'true' for local models
OLLAMA_MODELS="llama2,mistral"

# Monitoring (optional)
MONITORING_ENABLED="false"  # Set to 'true' for Prometheus + Grafana
GRAFANA_ADMIN_PASSWORD="changeme"

# Backup
BACKUP_RETENTION_DAYS="30"  # Keep backups for 30 days
BACKUP_ENABLED="true"
```

## File Preservation Strategy

Files in `/srv/nemoclaw/` are **never deleted** by `destroy.sh`:

| Path | Purpose | Survives Destroy |
|------|---------|------------------|
| `/srv/nemoclaw/config` | NemoClaw settings, API keys | ✓ |
| `/srv/nemoclaw/models` | Cached local models (if using Ollama) | ✓ |
| `/srv/nemoclaw/backups` | Automated backups | ✓ |
| `/srv/nemoclaw/logs` | Service logs | ✓ |
| Docker volumes | Temporary container data | ✗ (but backed up) |

**Restore workflow:**
1. `bash scripts/destroy.sh` → removes services, keeps `/srv/nemoclaw/`
2. Reinstall OS or refresh instance
3. Run `bash scripts/setup.sh` again
4. Run `bash scripts/restore.sh <backup>` → restores everything

## Daily Operations

### Start/Stop Services

```bash
# Start all services
docker compose up -d

# Stop all services (keeps data)
docker compose down

# Restart services
docker compose restart

# View logs
docker compose logs -f [service-name]
```

### Connect to Sandbox

```bash
# Interactive shell inside sandbox
nemoclaw my-assistant connect

# Inside sandbox, run OpenClaw
openclaw tui                    # Interactive TUI
openclaw agent -m "hello"       # Single message
```

### Monitor Resources

```bash
# System resources
free -h                         # Memory
df -h /srv                      # Disk
top -b -n 1 | head -15          # CPU

# Service status
docker compose ps
nemoclaw my-assistant status
openshell sandbox list
```

### View Logs

```bash
# NemoClaw/OpenShell logs
journalctl -u nemoclaw -f

# Docker service logs
docker compose logs -f [service]

# Sandbox event logs
openshell sandbox logs my-assistant
```

## Backup Schedule

Backups run **daily at 2 AM UTC** via cron:

```bash
# View cron job
crontab -l | grep nemoclaw

# Manual backup anytime
bash scripts/backup.sh

# Backups stored in: /srv/nemoclaw/backups/
# Automatic cleanup: older than 30 days (configurable in .env)
```

## Disaster Recovery

### Scenario: Disk Full

```bash
# Check disk usage
df -h

# Clean old backups
bash scripts/cleanup-old-backups.sh 14  # Keep 14 days

# Or remove oldest backup
ls -t /srv/nemoclaw/backups/ | tail -1 | xargs rm
```

### Scenario: Service Crash

```bash
# Restart all services
docker compose restart

# If that doesn't help, restore from backup
bash scripts/restore.sh <latest-backup>
```

### Scenario: Need Fresh Start

```bash
# Destroy all (keeps /srv/nemoclaw/)
bash scripts/destroy.sh --yes

# Verify nothing is running
docker compose ps

# Reinstall
bash scripts/setup.sh

# Restore state
bash scripts/restore.sh <backup>

# Verify
bash scripts/health-check.sh
```

## Security Considerations

- **API Keys**: Store `NVIDIA_API_KEY` in `.env`, never commit to git
- **SSH Access**: Use key-based authentication, disable password login
- **Firewall**: Restrict inbound to SSH (22) and monitoring dashboards if needed
- **Backups**: Consider encrypting backups for off-instance storage
- **Sandbox Policies**: Review `SANDBOX_POLICY` setting; `strict` is most secure

## Cost Estimation (Hetzner Pricing)

| Component | Cost | Notes |
|-----------|------|-------|
| CX43 Instance | €9.49/month | 8 vCPU, 16GB RAM, 160GB NVMe |
| Optional Backups | €0.50/GB/month | If using Hetzner backup add-on |
| NVIDIA API | Pay-per-token | Depends on usage |
| **Total (Base)** | ~€9.50/month | + API token costs |

## Getting Started

**Total deployment time:** ~15-20 minutes (provisioning + setup + onboarding)

1. **Provision CX43** on Hetzner
2. **SSH in** and run foundational setup: `bash scripts/setup.sh`
3. **Official NVIDIA installer** runs automatically (handles NemoClaw CLI + onboarding)
4. **Connect and chat:** `nemoclaw my-assistant connect` → `openclaw tui`
5. **(Optional) Telegram Bot:** Select during onboarding, then configure token
6. **(Optional) Supporting services:** Start Ollama, monitoring, backup runner

## Architecture

This deployment kit uses a **two-stage approach**:

| Stage | Tool | Responsibility |
|-------|------|-----------------|
| **Foundational** | `scripts/setup.sh` (ours) | Docker, Node.js, OpenShell, directories, systemd |
| **NemoClaw** | Official NVIDIA installer | NemoClaw CLI, onboarding, sandbox creation |

This separation **avoids npm PATH issues** and ensures we're always using the official, tested NemoClaw installer.

## Important: Idempotent Design

All setup and cleanup scripts are **idempotent** and **non-destructive by default**:

### setup.sh Behavior with Existing Packages

```bash
# Safe to run multiple times - checks for existing installations
bash scripts/setup.sh

# Docker: Keeps whatever version exists (no override)
# Node.js: Keeps if >= 20, upgrades if < 20 to v20.x
# OpenShell: Skips if already installed
```

✅ **Safe to re-run** if setup fails partway through
✅ **Won't override** working Docker installations
✅ **Flexible** with existing Node.js versions (>= 20)

### destroy.sh Flexibility

```bash
# Remove everything (complete cleanup)
bash scripts/destroy.sh --yes

# Keep common packages (if you want to reuse Docker/Node.js)
bash scripts/destroy.sh --yes --keep-docker-nodejs
bash scripts/destroy.sh --yes --keep-docker
bash scripts/destroy.sh --yes --keep-nodejs
```

✅ **Choose what to remove**
✅ **Reuse common packages** across different projects
✅ **Completely clean** if needed (vendor-agnostic)

See [OPERATIONS.md](docs/OPERATIONS.md#setup-and-destroy-reference) for detailed reference.

## For Detailed Information

- [OPERATIONS.md](docs/OPERATIONS.md) — Day-to-day tasks, monitoring, troubleshooting
- [STORAGE.md](docs/STORAGE.md) — Where data is stored, backup locations, persistence
- [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — Common issues and solutions
- [BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) — Backup procedures and disaster recovery
- [README.md](#quick-start) — This file (architecture and setup)

## Support

- **NemoClaw Docs**: https://docs.nvidia.com/nemoclaw/latest/
- **Discord Community**: https://discord.gg/XFpfPv9Uvx
- **Issues in this repo**: Create an issue for deployment-specific problems

## License

This deployment kit is provided as-is. NemoClaw itself is Apache 2.0 licensed.