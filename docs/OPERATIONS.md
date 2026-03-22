# NemoClaw Operations Guide

Daily operations, monitoring, and maintenance procedures for production NemoClaw deployment.

## Table of Contents
- [Setup & Teardown](#setup--teardown)
- [Starting Services](#starting-services)
- [Monitoring](#monitoring)
- [Common Tasks](#common-tasks)
- [Troubleshooting](#troubleshooting)
- [Performance Tuning](#performance-tuning)
- [Scaling](#scaling)

---

## Setup & Teardown

### Initial Installation (setup.sh)

The setup script is **idempotent** and **non-destructive** - safe to run multiple times:

```bash
# Initial installation (installs foundations)
bash scripts/setup.sh

# Re-running is safe (skips already-installed packages)
bash scripts/setup.sh

# With flags to skip certain components
bash scripts/setup.sh --skip-docker --skip-openshell
```

**Behavior with existing packages:**

| Package | Behavior | Idempotent |
|---------|----------|-----------|
| Docker | Keeps existing version (no override) | ✅ Yes |
| Node.js | Keeps if >= 20, upgrades if < 20 | ✅ Yes |
| OpenShell | Skips if already installed | ✅ Yes |

**When to re-run setup.sh:**
- Previous setup failed (network issues, etc.)
- You want to verify installation state
- Partial setup was interrupted
- Adding missing components

### Complete Teardown (destroy.sh)

Remove NemoClaw and optionally Docker/Node.js:

```bash
# Full cleanup (remove everything)
bash scripts/destroy.sh --yes

# Keep common packages (reuse for other projects)
bash scripts/destroy.sh --yes --keep-docker-nodejs

# Granular control
bash scripts/destroy.sh --yes --keep-docker      # Keep Docker, remove Node.js
bash scripts/destroy.sh --yes --keep-nodejs      # Keep Node.js, remove Docker
```

**What destroy.sh removes by default:**
- NemoClaw services and containers
- Docker installation
- Node.js installation  
- OpenShell package
- /srv/nemoclaw/ (config, models, backups, logs - EVERYTHING)
- Cron jobs
- nemoclaw user

**What it keeps:**
- OS packages (curl, wget, git, etc.)
- SSH access

**Important:** Always backup before destroying!

```bash
# Recommended workflow
bash scripts/backup.sh              # Back up everything
bash scripts/destroy.sh --yes       # Clean teardown
# Server is now clean
```

### Common Scenarios

**Scenario 1: Fresh reinstall (keep Docker/Node)**

```bash
bash scripts/backup.sh
bash scripts/destroy.sh --yes --keep-docker-nodejs
bash scripts/setup.sh
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

**Scenario 2: Complete cleanup (move to new VPS)**

```bash
bash scripts/backup.sh
bash scripts/destroy.sh --yes        # Remove everything
# Copy backup to new VPS and restore
bash scripts/restore.sh <backup-file>
bash scripts/setup.sh
```

**Scenario 3: Quick redeploy (package versions matter)**

```bash
# If you need specific Docker/Node versions
bash scripts/backup.sh
bash scripts/destroy.sh --yes --keep-docker-nodejs  # Keep working versions
bash scripts/setup.sh
```

---

## Starting Services

### Telegram Bridge (Optional)

If you added Telegram policy during onboarding, start the bridge:

```bash
# Export token from credentials file
export TELEGRAM_BOT_TOKEN=$(grep -o '"TELEGRAM_BOT_TOKEN":"[^"]*"' ~/.nemoclaw/credentials.json | cut -d'"' -f4)

# Verify it's set
echo $TELEGRAM_BOT_TOKEN

# Start all services (including Telegram)
nemoclaw start

# Verify bridge is running
nemoclaw status
# Should show: Telegram: bridge running
```

**To stop Telegram:**
```bash
nemoclaw stop
```

**Troubleshooting Telegram:**
See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md#telegram-bridge-issues)

### Initial Boot (After Installation)

```bash
# Verify setup is complete
bash scripts/health-check.sh

# Start Docker Compose services (Ollama, monitoring, backups)
docker compose --profile full up -d

# Monitor startup
docker compose logs -f
```

### Daily Operations

```bash
# Start all services
docker compose up -d

# Check status
docker compose ps

# View NemoClaw status
nemoclaw my-assistant status

# Check OpenShell gateway
openshell sandbox list
```

### Start/Stop Individual Services

```bash
# Start just the backup runner
docker compose --profile backups up -d backup-runner

# Stop just Ollama
docker compose down ollama

# Restart Prometheus + Grafana
docker compose --profile monitoring restart prometheus grafana
```

---

## Monitoring

### Quick Status Check

```bash
# Comprehensive health report
bash scripts/health-check.sh

# Detailed view
bash scripts/health-check.sh --verbose

# Only warnings
bash scripts/health-check.sh --warnings-only
```

### System Resources

```bash
# Memory and swap
free -h
watch -n 2 free -h

# Disk usage
df -h /srv/nemoclaw
du -sh /srv/nemoclaw/*

# CPU load
uptime
top -b -n 1 | head -20
```

### Docker Status

```bash
# Running containers
docker ps

# Detailed container status
docker compose ps

# View container logs
docker compose logs <service-name>
docker compose logs -f <service-name>  # Follow mode

# View specific lines
docker compose logs -n 50 <service-name>  # Last 50 lines
```

### NemoClaw / OpenShell Status

```bash
# Sandbox list
openshell sandbox list

# Sandbox logs
openshell sandbox logs my-assistant

# Detailed sandbox info
openshell sandbox info my-assistant

# NemoClaw status
nemoclaw my-assistant status

# NemoClaw logs
nemoclaw my-assistant logs --follow
```

### Grafana Dashboards

```bash
# Access Grafana
# Open browser to: http://localhost:3000
# Default credentials: admin / (password from .env GRAFANA_ADMIN_PASSWORD)

# Available dashboards:
# - Docker Containers (cAdvisor metrics)
# - Node Exporter (system metrics)
# - Prometheus (scraper status)
```

---

## Common Tasks

### Connecting to Your Assistant

```bash
# Open interactive shell in sandbox
nemoclaw my-assistant connect

# Inside sandbox, launch TUI
openclaw tui

# Or send single message via CLI
openclaw agent --agent main --local -m "hello" --session-id test
```

### Creating Backups

```bash
# Create immediate backup
bash scripts/backup.sh

# List available backups
bash scripts/backup.sh --list

# View backup details
ls -lh /srv/nemoclaw/backups/
tar -tzf /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | head -20
```

### Adding Local Models (Ollama)

```bash
# Connect to Ollama container
docker compose exec ollama bash

# Pull a model
ollama pull llama2
ollama pull mistral
ollama pull neural-chat

# List models
ollama list

# Test model
ollama run mistral "hello"
```

### Viewing Logs

```bash
# NemoClaw systemd service
journalctl -u nemoclaw -f

# Docker service logs
docker compose logs -f

# Specific service
docker compose logs -f ollama
docker compose logs -f prometheus

# Combine multiple services
docker compose logs -f ollama nemoclaw-backup-runner

# Search for errors
docker compose logs | grep -i error
journalctl -u nemoclaw | grep -i error
```

### Clearing Cache / Logs

```bash
# Clear old Docker logs
# (Docker logs are stored per container, remove container to clear)
docker compose down
docker compose up -d

# Clear application logs (keeps last 14 days by default)
# Handled automatically based on LOG_RETENTION_DAYS in .env

# Clear old backups manually
ls -1t /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | tail -n +6 | xargs rm
```

### Restarting Services

```bash
# Restart all services (clean)
docker compose restart

# Restart specific service
docker compose restart ollama
docker compose restart prometheus

# Hard restart (stops and removes containers, then starts)
docker compose down
docker compose up -d
```

---

## Troubleshooting

### Service Won't Start

```bash
# Check logs
docker compose logs <service>

# Check Docker daemon
docker ps

# Check disk/memory
free -h
df -h

# Rebuild service
docker compose down <service>
docker compose up -d <service>
```

### Ollama Connection Issues

```bash
# Verify Ollama is running
docker compose ps ollama

# Check Ollama logs
docker compose logs ollama

# Test connectivity
curl -s http://localhost:11434/api/tags
docker compose exec ollama ollama list

# Restart Ollama
docker compose restart ollama
```

### High Memory/CPU Usage

```bash
# Identify resource hogs
top -b -n 1 | head -20
docker stats

# Stop non-essential services
docker compose stop ollama prometheus grafana

# Check model size
du -sh /srv/nemoclaw/models/*

# Reduce Ollama model cache
# Remove unused models: ollama rm <model-name>
```

### Backup Issues

```bash
# Check backup directory
ls -lh /srv/nemoclaw/backups/

# Verify latest backup
bash scripts/backup.sh --test

# Check backup integrity
tar -tzf /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | wc -l

# Free up space if needed
du -sh /srv/nemoclaw/backups/
# Remove oldest backups manually if needed
```

### Network Connectivity

```bash
# Test internet
ping -c 1 8.8.8.8

# Test NVIDIA API endpoint
curl -I https://api.nvcf.com

# Test local services
curl -s http://localhost:3000       # Grafana
curl -s http://localhost:11434      # Ollama
curl -s http://localhost:9090       # Prometheus
```

### Sandbox Issues

```bash
# Check sandbox health
openshell sandbox status my-assistant

# View sandbox events
openshell term  # Opens TUI for live monitoring

# Restart sandbox
openshell sandbox stop my-assistant
openshell sandbox start my-assistant

# Delete and recreate sandbox
openshell sandbox destroy my-assistant
nemoclaw onboard  # Recreate during onboarding
```

---

## Performance Tuning

### Docker Resource Limits

In `docker-compose.yml`, adjust resource limits:

```yaml
services:
  ollama:
    deploy:
      resources:
        limits:
          cpus: '4'
          memory: 8G
        reservations:
          cpus: '2'
          memory: 4G
```

### Memory Management

```bash
# View memory usage breakdown
free -h
docker stats

# If memory low, prioritize essential services:
# 1. OpenShell Gateway (required)
# 2. NemoClaw (required)
# 3. Ollama (optional, disable if not needed)
# 4. Prometheus/Grafana (optional, can disable)

# Disable Ollama to free memory
docker compose down ollama

# Disable monitoring
docker compose down prometheus grafana node-exporter
```

### Disk Space

```bash
# Monitor disk usage
df -h /srv/nemoclaw

# Clean up old backups
bash scripts/backup.sh --list
# Keep only recent backups:
ls -1t /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | tail -n +6 | xargs rm

# Remove unused Docker images
docker image prune -f

# Remove unused Docker volumes
docker volume prune -f
```

### Network Performance

```bash
# Check bandwidth (if needed)
iftop  # requires package installation

# Monitor network connections
netstat -tunp
ss -tunp
```

---

## Scaling

### Running Multiple Sandboxes

```bash
# Create additional sandbox
nemoclaw onboard

# Connect to specific sandbox
nemoclaw <sandbox-name> connect

# List all sandboxes
openshell sandbox list
```

### Load Balancing

NemoClaw sandboxes are isolated by default. To load-balance across multiple sandboxes:

1. Create separate sandboxes with different resource allocations
2. Route requests to sandboxes based on criteria (round-robin, least-loaded, etc.)
3. Monitor per-sandbox resource usage

```bash
# Monitor resource usage per sandbox
openshell sandbox stats <sandbox-name>
docker stats | grep <sandbox-name>
```

### Using Different Models

```bash
# Switch default model in .env
INFERENCE_MODEL="nvidia/nemotron-3-8b-base"  # Smaller, faster

# Or add local Ollama models
docker compose --profile ollama up -d
ollama pull llama2
```

---

## Maintenance Schedule

### Daily
- `bash scripts/health-check.sh` — Check system status
- Review logs for errors: `docker compose logs | grep -i error`

### Weekly
- Review backup status: `bash scripts/backup.sh --list`
- Check disk usage: `df -h /srv/nemoclaw`
- Update models if using Ollama: `ollama pull <model>` (latest versions)

### Monthly
- Review and rotate logs: Check `/srv/nemoclaw/logs/`
- Clean up old backups: Keep last 30 days
- Review Grafana dashboards for trends
- Document any incidents or issues

### Quarterly
- Plan capacity upgrades if needed
- Review and update security policies
- Backup full system state before major changes

---

## Useful Command Reference

```bash
# Health & Status
bash scripts/health-check.sh                    # Full health report
docker compose ps                              # Service status
openshell sandbox list                         # Sandbox status
nemoclaw <name> status                         # Specific sandbox

# Logs & Debugging
docker compose logs -f <service>               # Stream service logs
journalctl -u nemoclaw -f                      # NemoClaw service logs
docker stats                                   # Real-time resource usage
top                                            # System process monitor

# Backup & Recovery
bash scripts/backup.sh                         # Create backup
bash scripts/backup.sh --list                  # List backups
bash scripts/restore.sh <backup>               # Restore from backup

# Connection
nemoclaw <name> connect                        # SSH into sandbox
openclaw tui                                   # Interactive chat (in sandbox)
openclaw agent -m "message"                    # Send message (in sandbox)

# Services
docker compose up -d                           # Start all services
docker compose down                            # Stop all services
docker compose restart <service>               # Restart service
docker compose exec <svc> <cmd>                # Run command in service

# Cleanup
docker system prune -f                         # Clean unused Docker resources
docker logs --help                             # Docker log options
```

---

## FAQ: Setup & Destroy

**Q: What happens if I run setup.sh multiple times?**

A: It's safe and idempotent. Already-installed packages are skipped:
- Docker: Keeps existing version
- Node.js: Keeps if >= 20, upgrades if < 20
- OpenShell: Skips if already installed

Useful for fixing partial installations or verifying state.

---

**Q: Will setup.sh override my existing Docker/Node versions?**

A: No. setup.sh explicitly checks for existing installations and skips:

```bash
if command -v docker &> /dev/null; then
    return 0  # Skip - keep existing
fi
```

This preserves your working setup.

---

**Q: Does destroy.sh delete my backups?**

A: By default, yes. `/srv/nemoclaw/` is removed completely (including backups).

**Always backup first:**
```bash
bash scripts/backup.sh         # Create backup BEFORE destroy
bash scripts/destroy.sh --yes  # Then destroy
```

You can keep the backup somewhere else (upload to cloud storage, external disk, etc.).

---

**Q: Can I keep Docker and Node.js when destroying?**

A: Yes, use the `--keep-*` flags:

```bash
# Keep both
bash scripts/destroy.sh --yes --keep-docker-nodejs

# Keep individually
bash scripts/destroy.sh --yes --keep-docker
bash scripts/destroy.sh --yes --keep-nodejs
```

Useful for:
- Reusing Docker/Node across projects
- Avoiding reinstallation if you have specific versions
- Quick NemoClaw redeploys

---

**Q: What's the difference between destroy.sh and just deleting the VPS?**

A: `destroy.sh` is **vendor-agnostic**:
- Works on any VPS provider (Hetzner, DigitalOcean, AWS, etc.)
- No dependence on snapshots or provider features
- Clean removal of all components
- Leaves server ready for new projects

Deleting the VPS only works if your provider supports it.

---

**Q: How do I reinstall NemoClaw after destroy?**

A: Simple workflow:

```bash
bash scripts/destroy.sh --yes --keep-docker-nodejs
bash scripts/setup.sh
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

Or restore from backup:

```bash
bash scripts/restore.sh <backup-file>
```

---

## Getting Help

- **Logs First**: Always check `docker compose logs` and `journalctl` for error details
- **Health Check**: Run `bash scripts/health-check.sh --verbose` for diagnostics
- **NemoClaw Docs**: https://docs.nvidia.com/nemoclaw/latest/
- **Discord Community**: https://discord.gg/XFpfPv9Uvx
- **This Repository**: Issues and discussions

---

For advanced topics, see:
- [BACKUP-RESTORE.md](BACKUP-RESTORE.md) — Detailed backup procedures
- [README.md](README.md) — Architecture and installation
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — Advanced troubleshooting