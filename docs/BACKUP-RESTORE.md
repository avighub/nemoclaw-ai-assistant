# NemoClaw Backup & Restore Guide

Complete procedures for creating, storing, and restoring backups.

## Overview

The backup strategy preserves:
- **Configuration** — NemoClaw settings, API keys, sandbox policies
- **Models** — Cached Ollama models (if using local inference)
- **State** — Sandbox states, logs, history
- **Metadata** — Service configuration, cron jobs

Backups are stored in `/srv/nemoclaw/backups/` and automatically cleaned up based on retention policy.

---

## Backup Contents

Each backup (`nemoclaw-backup-YYYY-MM-DD-HH-MM-SS.tar.gz`) contains:

```
nemoclaw-data/
├── config/               # NemoClaw configuration, API keys, policies
├── models/               # Ollama model cache
└── logs/                 # Service logs and events
```

**Not included** (and why):
- Docker images — Too large, can be re-pulled
- Container volumes — Can be regenerated
- System packages — Reinstalled by `setup.sh`

---

## Automatic Backups

Backups run **daily at 2:00 AM UTC** (configurable in `.env`):

```bash
# Enable/disable in .env
BACKUP_ENABLED="true"
BACKUP_TIME="02:00"
BACKUP_RETENTION_DAYS="30"
```

**Cron job location:**
```bash
crontab -l | grep nemoclaw
```

**Verify cron is working:**
```bash
# Check last backup date
ls -lt /srv/nemoclaw/backups/ | head -5

# Monitor next scheduled run
systemctl status cron
journalctl -u cron -f
```

---

## Manual Backup

Create a backup anytime:

```bash
# Standard backup
bash scripts/backup.sh

# With verbose output
bash scripts/backup.sh --verbose

# Override retention (keep 60 days instead of 30)
bash scripts/backup.sh --retention 60

# Skip automatic cleanup of old backups
bash scripts/backup.sh --no-cleanup
```

**Output:**
```
[INFO] ═════════════════════════════════════════════════════════
[INFO] NemoClaw Backup
[INFO] ═════════════════════════════════════════════════════════
[INFO] Creating backup: /srv/nemoclaw/backups/nemoclaw-backup-2025-03-22-14-30-00.tar.gz
[SUCCESS] Backup created: /srv/nemoclaw/backups/nemoclaw-backup-2025-03-22-14-30-00.tar.gz (2.3 GB)
[SUCCESS] Manifest created: /srv/nemoclaw/backups/nemoclaw-backup-2025-03-22-14-30-00.manifest
```

---

## Listing Backups

View available backups:

```bash
# List via script
bash scripts/backup.sh --list

# Manual listing
ls -lh /srv/nemoclaw/backups/

# Find backups older than 30 days
find /srv/nemoclaw/backups -name "nemoclaw-backup-*.tar.gz" -mtime +30

# Disk space used
du -sh /srv/nemoclaw/backups/
```

**Example output:**
```
Existing backups:

Backup File                                  Size         Created             Age
────────────────────────────────────────────────────────────────────────────────
nemoclaw-backup-2025-03-22-14-30-00.tar.gz  2.3 GB       2025-03-22 14:30:00 2h
nemoclaw-backup-2025-03-21-02-00-00.tar.gz  2.1 GB       2025-03-21 02:00:00 1d
nemoclaw-backup-2025-03-20-02-00-00.tar.gz  2.2 GB       2025-03-20 02:00:00 2d

Total backup storage: 6.6 GB
```

---

## Verifying Backup Integrity

```bash
# Test backup (lists contents without extracting)
bash scripts/backup.sh --test

# Manual verification
tar -tzf /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz > /dev/null

# Check file count
tar -tzf /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | wc -l

# View specific files
tar -tzf /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | grep "config/"
```

---

## Restore from Backup

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

# Don't create pre-restore safety backup (fast)
bash scripts/restore.sh nemoclaw-backup-*.tar.gz --no-backup

# Verbose output
bash scripts/restore.sh nemoclaw-backup-*.tar.gz --verbose
```

### Restore Process

```bash
# 1. Interactive confirmation
# 2. Creates safety backup of current state
# 3. Stops services gracefully
# 4. Extracts backup files
# 5. Starts services
# 6. Verifies restoration
# 7. Reports status
```

**On success:**
```
[SUCCESS] Restoration completed successfully!

Restored from: nemoclaw-backup-2025-03-22-14-30-00.tar.gz
Restored at:  2025-03-22 16:45:30

Data Locations:
  - Config: /srv/nemoclaw/config
  - Models: /srv/nemoclaw/models
  - Logs:   /srv/nemoclaw/logs

Next Steps:
  1. Verify services: docker compose ps
  2. Check status: nemoclaw my-assistant status
  3. View logs: docker compose logs -f
  4. Connect: nemoclaw my-assistant connect
```

---

## Disaster Recovery Scenarios

### Scenario 1: Accidental Configuration Change

```bash
# Find backup taken before the change
bash scripts/backup.sh --list

# Restore that backup
bash scripts/restore.sh nemoclaw-backup-2025-03-20-02-00-00.tar.gz

# Or just restore the config file manually
tar -xzf /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz \
  -C / nemoclaw-data/config/
```

### Scenario 2: Service Corruption

```bash
# Restore full backup
bash scripts/restore.sh <backup-file>

# Verify all services healthy
bash scripts/health-check.sh
```

### Scenario 3: Disk Full

```bash
# List backups by size
ls -lhS /srv/nemoclaw/backups/

# Delete oldest backups to free space
ls -1t /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | tail -n +6 | xargs rm

# Or run cleanup with custom retention
bash scripts/backup.sh --retention 7  # Keep only 7 days

# Clean Docker
docker system prune -f
```

### Scenario 4: Need Fresh Start But Keep Data

```bash
# Backup current state
bash scripts/backup.sh

# Destroy all services (keeps /srv/nemoclaw/)
bash scripts/destroy.sh --yes

# Reinstall
bash scripts/setup.sh

# Restore backup
bash scripts/restore.sh <backup-file>
```

### Scenario 5: Move to Different Server

```bash
# On original server: Create final backup
bash scripts/backup.sh

# Transfer backup to new server
scp /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz \
  user@newserver:/tmp/backup.tar.gz

# On new server:
# 1. Install NemoClaw
bash scripts/setup.sh

# 2. Restore backup
bash scripts/restore.sh /tmp/backup.tar.gz
```

---

## Off-Instance Backup (Cloud Storage)

For redundancy, keep backups off the instance.

### AWS S3 Example

```bash
# Install AWS CLI
apt-get install awscli

# Configure credentials
aws configure

# Upload backup to S3
aws s3 cp /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz \
  s3://your-bucket/nemoclaw-backups/

# Download backup from S3
aws s3 cp \
  s3://your-bucket/nemoclaw-backups/nemoclaw-backup-*.tar.gz \
  /tmp/backup.tar.gz

# Sync entire backup directory
aws s3 sync /srv/nemoclaw/backups/ \
  s3://your-bucket/nemoclaw-backups/
```

### Google Cloud Storage Example

```bash
# Install gsutil
curl https://sdk.cloud.google.com | bash

# Upload backup
gsutil cp /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz \
  gs://your-bucket/nemoclaw-backups/

# Download
gsutil cp \
  gs://your-bucket/nemoclaw-backups/nemoclaw-backup-*.tar.gz \
  /tmp/backup.tar.gz
```

### Automated Off-Site Backup Script

```bash
#!/bin/bash
# Backup to S3 daily at 3 AM

# Add to crontab:
# 0 3 * * * /usr/local/bin/backup-to-s3.sh

BACKUP_DIR="/srv/nemoclaw/backups"
S3_BUCKET="s3://your-bucket/nemoclaw-backups"

# Find latest backup
latest=$(ls -1t "$BACKUP_DIR"/nemoclaw-backup-*.tar.gz | head -1)

if [[ -n "$latest" ]]; then
  # Upload to S3
  aws s3 cp "$latest" "$S3_BUCKET/"
  
  # Log success
  echo "Backup uploaded: $(basename $latest)" >> /var/log/backup-to-s3.log
else
  echo "No backup found" >> /var/log/backup-to-s3.log
fi
```

---

## Backup Lifecycle

### Automatic Retention

Backups older than `BACKUP_RETENTION_DAYS` are automatically deleted:

```bash
# In .env
BACKUP_RETENTION_DAYS="30"

# Cleanup happens:
# 1. After each backup.sh run
# 2. Daily at 2 AM via cron
```

### Manual Cleanup

```bash
# Remove backups older than 14 days
find /srv/nemoclaw/backups -name "nemoclaw-backup-*.tar.gz" -mtime +14 -delete

# Keep only the 5 most recent
ls -1t /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | tail -n +6 | xargs rm

# Remove all backups (careful!)
rm /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz
```

---

## Backup Monitoring

### Check Backup Health

```bash
# Did backup run recently?
stat /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | grep Modify

# How old is the latest backup?
backup_age=$(($(date +%s) - $(stat -c %Y /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz | head -1)))
echo "Latest backup is $((backup_age / 3600)) hours old"

# Backup size trend (growing disk usage?)
du -sh /srv/nemoclaw/backups/
```

### Email Alerts (Optional)

Add to `docker-compose.yml`:

```yaml
  backup-mailer:
    image: alpine:latest
    entrypoint: |
      sh -c 'apk add --no-cache mail msmtp cron
             crond -f'
    environment:
      - SMTP_SERVER=smtp.gmail.com
      - SMTP_USER=your-email@gmail.com
      - SMTP_PASS=${SMTP_PASSWORD}
```

---

## Backup Encryption

For additional security, encrypt backups:

```bash
# Encrypt backup with gpg
gpg -c /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz
# Creates: nemoclaw-backup-*.tar.gz.gpg

# Decrypt and restore
gpg -d /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz.gpg | tar -xz -C /
```

Or use `openssl`:

```bash
# Encrypt
openssl enc -aes-256-cbc -salt -in nemoclaw-backup-*.tar.gz \
  -out nemoclaw-backup-*.tar.gz.enc

# Decrypt and restore
openssl enc -d -aes-256-cbc -in nemoclaw-backup-*.tar.gz.enc | tar -xz -C /
```

---

## Best Practices

✅ **Do:**
- Run backups automatically daily
- Keep 30 days of backups minimum
- Test restore procedures quarterly
- Store off-instance backups in cloud storage
- Encrypt sensitive backups
- Monitor backup size and age
- Document restore procedures

❌ **Don't:**
- Rely on single backup copy
- Keep backups only on the same disk
- Ignore backup failures silently
- Restore without verifying integrity
- Delete all backups at once
- Backup to insufficient disk space

---

## Troubleshooting

### Backup Fails

```bash
# Check space
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

# Check services stopped
docker compose ps
systemctl status nemoclaw

# Try with verbose output
bash scripts/restore.sh nemoclaw-backup-*.tar.gz --verbose
```

### Slow Backups

```bash
# Reduce backup size (remove old models)
du -sh /srv/nemoclaw/models/
ls -lhS /srv/nemoclaw/models/

# Use faster compression
# Edit backup.sh: tar -czf → tar -cjf (bzip2)

# Run during low-usage time
# Edit .env: BACKUP_TIME="03:00"  # Off-peak
```

---

## Reference

- **Location**: `/srv/nemoclaw/backups/`
- **Schedule**: Daily at 2:00 AM UTC (configurable)
- **Retention**: 30 days (configurable)
- **Max size per backup**: Varies (typically 2-4 GB)
- **Estimated restore time**: 5-10 minutes

For more information, see:
- [OPERATIONS.md](OPERATIONS.md) — Daily operations
- [README.md](../README.md) — Architecture overview