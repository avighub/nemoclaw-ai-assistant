# NemoClaw Backup & Restore Guide

Complete reference for storage architecture, backup procedures, and data restoration.

---

## Quick Reference

| What | Where |
|------|-------|
| All persistent data | `/srv/nemoclaw/` |
| Conversations & soul.md | Docker volume `openshell-cluster-nemoclaw` (SQLite) |
| Credentials | `~/.nemoclaw/credentials.json` |
| Sandbox registry | `~/.nemoclaw/sandboxes.json` |
| Backups | `/srv/nemoclaw/backups/` |

When you restore from backup, all conversation history, soul.md, and assistant personality come back with it.

---

## Storage Architecture

### Main Data Directory: `/srv/nemoclaw/`

```
/srv/nemoclaw/
├── config/           # NemoClaw configuration (backed up)
│   ├── sandboxes.json
│   └── policies/
├── logs/             # Service logs (backed up)
└── backups/          # Backup files
    ├── nemoclaw-backup-2026-03-22-14-30-00.tar.gz
    ├── nemoclaw-backup-2026-03-22-14-30-00.manifest
    └── ...
```

### User Home Directories

NemoClaw runs as root:
```
/root/.nemoclaw/
├── credentials.json      # API keys, bot tokens (mode 600)
├── sandboxes.json        # Sandbox registry
└── source/               # NemoClaw source code not backed up (recreated by setup.sh)
```

### OpenShell Sandbox Data (Docker Volume)

This is where your assistant's personality and conversations live.

```
Docker Volume: openshell-cluster-nemoclaw
Location: /var/lib/docker/volumes/openshell-cluster-nemoclaw/_data/

└── storage/pvc-*/openshell.db    # SQLite database containing:
    ├── soul.md                    # Assistant personality/instructions
    ├── All conversation history
    ├── System prompts & context
    ├── Sandbox metadata & state
    └── All assistant knowledge
```

OpenShell uses a **single SQLite database** (`openshell.db`) — backing up the entire Docker volume ensures complete, consistent recovery.

### Credentials Storage

**On disk (protected by OS permissions):**
```
~/.nemoclaw/credentials.json (mode 600 — read-only by owner)
```
```json
{
  "NVIDIA_API_KEY": "nvapi-...",
  "TELEGRAM_BOT_TOKEN": "123456:ABC...",
  "GITHUB_TOKEN": "ghp_..."
}
```

> ⚠️ Backups contain credentials. Treat backup files as secrets and restrict permissions (`chmod 600`).

---

## What Gets Backed Up

### Always included (critical data)

```
home/.nemoclaw/
├── credentials.json        # API keys, Telegram token
└── sandboxes.json          # Sandbox registry

docker-volumes/openshell-cluster-nemoclaw/
└── _data/
    ├── storage/            # openshell.db (soul.md, conversations, all state)
    ├── server/             # OpenShell server config
    └── agent/              # OpenShell agent state
```

### Conditionally included

- `/srv/nemoclaw/models/` — Only if Ollama models exist (skip with `--no-models`)
- `/srv/nemoclaw/logs/` — Optional (skip with `--no-logs`)

### Not included (and why)

- Docker images — Too large, can be re-pulled
- Empty directories — Automatically skipped
- System packages — Reinstalled by `setup.sh`

---

## Automatic Backups

Backups run **daily at 2:00 AM UTC**, configured in `.env`:

```bash
BACKUP_ENABLED="true"
BACKUP_TIME="02:00"
BACKUP_RETENTION_DAYS="30"
```

**Cron entry created by `setup.sh`:**
```bash
00 02 * * * cd /root/nemoclaw-ai-assistant && bash scripts/backup.sh >> /var/log/nemoclaw-backup.log 2>&1
```

**Verify cron is working:**
```bash
# Check cron entry
crontab -l | grep nemoclaw

# Check cron daemon status
systemctl status cron

# View execution logs
tail -f /var/log/nemoclaw-backup.log

# Check latest backup
ls -lt /srv/nemoclaw/backups/ | head -5
```

**Change backup schedule:**
1. Edit `.env`: `BACKUP_TIME="03:00"`
2. Re-run `bash scripts/setup.sh` (idempotent — safe to re-run)

**Disable automatic backups:**
```bash
crontab -u nemoclaw -e  # Delete the backup.sh line
```

---

## Manual Backups

```bash
# Standard backup
bash scripts/backup.sh

# Dry-run (preview what would be backed up)
bash scripts/backup.sh --test

# Minimal backup (skip models and logs)
bash scripts/backup.sh --no-models --no-logs

# Custom retention period
bash scripts/backup.sh --retention 60

# Skip automatic cleanup of old backups
bash scripts/backup.sh --no-cleanup

# Verbose output
bash scripts/backup.sh --verbose

# List existing backups
bash scripts/backup.sh --list
```

**Example output:**
```
[INFO] Determining what to backup...

[INFO] Critical data:
  ✓ ~/.nemoclaw/credentials.json
  ✓ ~/.nemoclaw/sandboxes.json
  ✓ Docker volume openshell-cluster-nemoclaw (125 MB)
    (contains openshell.db with soul.md, conversations, sandbox state)

[INFO] Optional data:
  ○ /srv/nemoclaw/models (empty, skipping)
  ○ /srv/nemoclaw/logs (empty, skipping)

[SUCCESS] Backup created: /srv/nemoclaw/backups/nemoclaw-backup-2026-03-22-18-30-00.tar.gz (140 MB)
[SUCCESS] Manifest created: nemoclaw-backup-2026-03-22-18-30-00.manifest
```

---

## Listing & Verifying Backups

```bash
# List via script
bash scripts/backup.sh --list

# Manual listing
ls -lh /srv/nemoclaw/backups/

# Disk space used
du -sh /srv/nemoclaw/backups/

# Verify integrity (lists contents without extracting)
tar -tzf /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz > /dev/null

# Check file count
tar -tzf /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | wc -l
```

---

## Restore Procedures

### Quick Restore

```bash
# Restore latest backup
latest=$(ls -1t /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | head -1)
bash scripts/restore.sh "$latest"

# Or by filename
bash scripts/restore.sh nemoclaw-backup-2025-03-22-14-30-00.tar.gz
```

### Restore Options

```bash
# Verify backup without restoring
bash scripts/restore.sh nemoclaw-backup-*.tar.gz --verify-only

# Skip confirmation prompt
bash scripts/restore.sh nemoclaw-backup-*.tar.gz --force

# Don't create pre-restore safety backup (faster)
bash scripts/restore.sh nemoclaw-backup-*.tar.gz --no-backup

# Verbose output
bash scripts/restore.sh nemoclaw-backup-*.tar.gz --verbose
```

### Restore Process (what happens)

1. Interactive confirmation
2. Creates safety backup of current state
3. Stops services gracefully
4. Extracts backup files
5. Starts services
6. Verifies restoration
7. Reports status

**On success, what's restored:**
- ✅ soul.md (personality)
- ✅ All conversation history
- ✅ API keys and credentials
- ✅ Sandbox configuration & state
- ✅ Ollama models (if included in backup)

---

## Migration & Disaster Recovery

### Move to a New Server

```bash
# 1. On original server — create final backup
bash scripts/backup.sh

# 2. Transfer to new server
scp /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz user@newserver:/tmp/

# 3. On new server — install NemoClaw
bash scripts/setup.sh

# 4. Restore
cp /tmp/nemoclaw-backup-*.tar.gz /srv/nemoclaw/backups/
bash scripts/restore.sh nemoclaw-backup-YYYY-MM-DD-HH-MM-SS.tar.gz

# 5. Verify
nemoclaw list
nemoclaw my-assistant status
nemoclaw my-assistant connect
```

### Recover from Accidental Change

```bash
# Find backup taken before the change
bash scripts/backup.sh --list

# Restore that specific backup
bash scripts/restore.sh nemoclaw-backup-2025-03-20-02-00-00.tar.gz

# Or restore only the config file
tar -xzf /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz -C / nemoclaw-data/config/
```

### Fresh Start (Keep Data)

```bash
bash scripts/backup.sh          # Backup current state
bash scripts/destroy.sh --yes   # Destroy all services
bash scripts/setup.sh           # Reinstall
bash scripts/restore.sh <backup-file>  # Restore data
```

### Disk Full

```bash
# Check usage
df -h /srv/nemoclaw
ls -lhS /srv/nemoclaw/backups/

# Trim old backups
bash scripts/backup.sh --retention 7   # Keep only 7 days
ls -1t /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | tail -n +6 | xargs rm

# Clean Docker
docker system prune -f
```

### Disaster Recovery Checklist

**Before something goes wrong:**
- [ ] `bash scripts/backup.sh` — backup created
- [ ] Backup copied offsite
- [ ] Restore tested locally: `bash scripts/restore.sh <backup>`
- [ ] Credentials saved securely

**If disaster happens:**
1. New server → follow "Move to a New Server" above
2. Same server restore → `bash scripts/restore.sh <backup>`
3. Lost credentials → recreate `~/.nemoclaw/credentials.json`
4. Lost all backups → recreate with `nemoclaw onboard`

---

## Off-Instance Backup (Cloud Storage)

### AWS S3

```bash
# Upload
aws s3 cp /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz s3://your-bucket/nemoclaw-backups/

# Download
aws s3 cp s3://your-bucket/nemoclaw-backups/nemoclaw-backup-*.tar.gz /tmp/backup.tar.gz

# Sync entire directory
aws s3 sync /srv/nemoclaw/backups/ s3://your-bucket/nemoclaw-backups/
```

### Google Cloud Storage

```bash
# Upload
gsutil cp /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz gs://your-bucket/nemoclaw-backups/

# Download
gsutil cp gs://your-bucket/nemoclaw-backups/nemoclaw-backup-*.tar.gz /tmp/backup.tar.gz
```

### Automated Off-Site Script

```bash
#!/bin/bash
# Add to crontab: 0 3 * * * /usr/local/bin/backup-to-s3.sh

BACKUP_DIR="/srv/nemoclaw/backups"
S3_BUCKET="s3://your-bucket/nemoclaw-backups"

latest=$(ls -1t "$BACKUP_DIR"/nemoclaw-backup-*.tar.gz | head -1)
if [[ -n "$latest" ]]; then
  aws s3 cp "$latest" "$S3_BUCKET/"
  echo "Backup uploaded: $(basename $latest)" >> /var/log/backup-to-s3.log
else
  echo "No backup found" >> /var/log/backup-to-s3.log
fi
```

---

## Backup Lifecycle

### Automatic Retention

```bash
# In .env
BACKUP_RETENTION_DAYS="30"
```

Backups older than the retention period are deleted after each `backup.sh` run and daily via cron.

### Manual Cleanup

```bash
# Remove backups older than 14 days
find /srv/nemoclaw/backups -name "nemoclaw-backup-*.tar.gz" -mtime +14 -delete

# Keep only the 5 most recent
ls -1t /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | tail -n +6 | xargs rm

# Preserve a backup from cleanup (move it elsewhere)
cp /srv/nemoclaw/backups/nemoclaw-backup-2026-01-15-*.tar.gz ~/my-backups/
```

---

## Backup Monitoring

```bash
# Check when last backup ran
ls -lt /srv/nemoclaw/backups/ | head -5

# How old is the latest backup?
backup_age=$(($(date +%s) - $(stat -c %Y /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | head -1)))
echo "Latest backup is $((backup_age / 3600)) hours old"

# Disk usage trend
du -sh /srv/nemoclaw/backups/
```

---

## Backup Encryption

```bash
# Encrypt with gpg
gpg -c /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz
# Creates: nemoclaw-backup-*.tar.gz.gpg

# Decrypt and restore
gpg -d /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz.gpg | tar -xz -C /
```

Or with `openssl`:

```bash
# Encrypt
openssl enc -aes-256-cbc -salt \
  -in nemoclaw-backup-*.tar.gz \
  -out nemoclaw-backup-*.tar.gz.enc

# Decrypt and restore
openssl enc -d -aes-256-cbc -in nemoclaw-backup-*.tar.gz.enc | tar -xz -C /
```

---

## Storage Size Estimates

```
/srv/nemoclaw/
├── config/          ~10 MB
├── logs/            ~500 MB (grows over time)
└── backups/         ~20 GB  (30 days of daily backups)

Total: ~30–40 GB for active deployment + backups
```

```bash
# Check current usage
du -sh /srv/nemoclaw/
du -sh /srv/nemoclaw/*
```

---

## Best Practices

✅ **Do:**
- Run backups automatically daily
- Keep 30 days of backups minimum
- Test restore procedures quarterly
- Store off-instance backups in cloud storage
- Encrypt sensitive backups before uploading
- Monitor backup size and age

❌ **Don't:**
- Rely on a single backup copy
- Keep backups only on the same disk
- Ignore backup failures silently
- Restore without verifying integrity first
- Backup to insufficient disk space

---

## Troubleshooting

### Backup Fails

```bash
# Check disk space
df -h /srv/nemoclaw
du -sh /srv/nemoclaw/backups/

# Check permissions
ls -ld /srv/nemoclaw/backups/

# Check logs
docker compose logs backup-runner
journalctl -u cron -f
```

### Restore Fails

```bash
# Verify backup integrity first
tar -tzf /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz > /dev/null

# Check disk space
df -h /

# Check services are stopped
docker compose ps

# Try with verbose output
bash scripts/restore.sh nemoclaw-backup-*.tar.gz --verbose
```

### Slow Backups

```bash
# Check model sizes (often the culprit)
du -sh /srv/nemoclaw/models/

# Skip models in backup
bash scripts/backup.sh --no-models

# Schedule during off-peak hours
# Edit .env: BACKUP_TIME="03:00"
```

---

## FAQ

**Q: Does soul.md back up automatically?**
A: Yes — it lives inside the OpenShell Docker volume, which is backed up daily.

**Q: If I restore an old backup, do I lose recent conversations?**
A: Yes, you revert to that point in time. Keep recent backups accessible.

**Q: Are credentials backed up?**
A: Yes, `credentials.json` is included. Treat backup files as secrets.

**Q: Can I move `/srv/nemoclaw/` to another drive?**
A: Yes, but update paths in `~/.nemoclaw/config/` and cron jobs. Easier: use backup + restore on the new location.

**Q: If I lose `/srv/nemoclaw/`, can I recover?**
A: If an offsite backup exists, yes — restore from it. If no backup exists, all conversations and config are lost, but you can start fresh with `nemoclaw onboard`.

---

## Reference

| Item | Value |
|------|-------|
| Backup location | `/srv/nemoclaw/backups/` |
| Schedule | Daily at 2:00 AM UTC (configurable) |
| Retention | 30 days (configurable) |
| Typical backup size | 140 MB – 4 GB (depends on models) |
| Estimated restore time | 5–10 minutes |

For more information, see:
- [OPERATIONS.md](OPERATIONS.md) — Daily operations
- [README.md](../README.md) — Architecture overview
