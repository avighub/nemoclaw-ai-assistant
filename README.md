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
4. **SSH Key:** Select your public key (from your laptop)
5. **Location:** Choose nearest to you (Frankfurt, Helsinki, etc.)
6. Click **"Create & Buy now"**

Wait 2-3 minutes for server to boot. Once status shows **"Running"**:

```bash
# SSH into your new instance
ssh root@<instance-ip>

# You should be logged in without a password
# Everything else is automated by setup.sh
```

### 2. Deploy NemoClaw

```bash
# Create deployment directory
cd /home/nemoclaw/nemoclaw-deploy

# Copy your .env configuration (see .env.example)
cp .env.example .env
# Edit .env with your NVIDIA API key
nano .env

# Run automated setup (installs everything - system update, user creation, Docker, NemoClaw)
bash scripts/setup.sh
```

**What setup.sh does automatically:**
- Updates system packages (`apt update && apt upgrade`)
- Creates `nemoclaw` non-root user (if it doesn't exist)
- Installs Docker, Node.js, npm, OpenShell
- Installs NemoClaw globally
- Creates persistent storage directories (`/srv/nemoclaw/config`, etc.)
- Sets up systemd service and cron jobs
- Runs initial NemoClaw onboarding (interactive)

**Setup time:** ~5-10 minutes (depending on internet speed)

Verify installation:
```bash
bash scripts/health-check.sh
```

### 3. Start Services

```bash
# Start supporting services (Ollama, monitoring, backup runner)
docker compose up -d

# Or just the essentials (no Ollama/monitoring):
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

## Next Steps

1. **Provision CX43** on Hetzner (see Quick Start above)
2. **Copy deployment files** to your laptop/instance
3. **Configure .env:**
   ```bash
   cp .env.example .env
   nano .env  # Add your NVIDIA_API_KEY
   ```
4. **Run setup** (one command, fully automated):
   ```bash
   bash scripts/setup.sh
   ```
5. **Verify installation:**
   ```bash
   bash scripts/health-check.sh
   ```
6. **Connect and chat:**
   ```bash
   nemoclaw my-assistant connect
   openclaw tui  # Inside the sandbox
   ```

**All-in-one deployment:** ~15 minutes total (provisioning + setup + onboarding)

For detailed guides, see:
- [OPERATIONS.md](docs/OPERATIONS.md) — Day-to-day tasks and monitoring
- [BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) — Backup and disaster recovery
- [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — Common issues and solutions

## Support

- **NemoClaw Docs**: https://docs.nvidia.com/nemoclaw/latest/
- **Discord Community**: https://discord.gg/XFpfPv9Uvx
- **Issues in this repo**: Create an issue for deployment-specific problems

## License

This deployment kit is provided as-is. NemoClaw itself is Apache 2.0 licensed.