# NemoClaw Storage & Data Persistence Guide

Complete reference for where all data is stored, backed up, and restored.

## Quick Answer

**TL;DR:**
- 📁 All persistent data: `/srv/nemoclaw/` 
- 💬 Conversation history & soul.md: Inside OpenShell sandbox (backed up)
- 🔐 Credentials: `~/.nemoclaw/credentials.json` (backed up)
- ⚙️ Config: `~/.nemoclaw/sandboxes.json` (backed up)
- 🗂️ Backups: `/srv/nemoclaw/backups/`

When you **restore from backup**, all conversation history, soul.md, and assistant personality come back with it.

---

## Storage Architecture

### Main Data Directory: `/srv/nemoclaw/`

```
/srv/nemoclaw/
├── config/           # NemoClaw configuration (backed up)
│   ├── sandboxes.json       # Sandbox registry & metadata
│   └── policies/            # Security policies
├── logs/             # Service logs (backed up)
│   ├── nemoclaw.log
│   ├── openshell.log
│   └── ...
└── backups/          # Backup files (backed up by backup script)
    ├── nemoclaw-backup-2026-03-22-14-30-00.tar.gz
    ├── nemoclaw-backup-2026-03-22-14-30-00.manifest
    └── ...
```

**All these directories are backed up by `bash scripts/backup.sh`**

### User Home Directories

**NemoClaw runs as root, everything is in:**
```
/root/.nemoclaw/
├── credentials.json      # API keys, bot tokens (backed up)
├── sandboxes.json        # Sandbox registry (backed up)
└── source/               # NemoClaw source code
```

**Note:** The `nemoclaw` system user exists for running services but doesn't have its own NemoClaw configuration directory. All NemoClaw state is stored under root.

**Everything backed up from here** - see Backup section below.

---

## OpenShell Sandbox Data (Docker Volume)

**This is where your assistant's personality and conversations live!**

OpenShell runs in Docker containers, and all sandbox data is stored in a **Docker volume**:

```
Docker Volume: openshell-cluster-nemoclaw
Location: /var/lib/docker/volumes/openshell-cluster-nemoclaw/_data/

Critical Database (contains ALL sandbox data):
└── storage/pvc-*/openshell.db
    ├── soul.md              # Assistant personality/instructions
    ├── Conversations        # All conversation history
    ├── Context              # Conversation context
    ├── Sandbox configuration
    └── All assistant state
```

### How Data is Stored

Unlike traditional file-based storage, OpenShell uses a **SQLite database** (`openshell.db`) to store:
- `soul.md` — Your assistant's personality/instructions
- **All conversation history** — Every message and interaction
- System prompts and configuration
- Sandbox metadata and state
- All assistant knowledge and memories

### What Gets Backed Up

The backup script backs up:
- **Entire Docker volume** — `/var/lib/docker/volumes/openshell-cluster-nemoclaw/_data/`
  - Complete openshell.db (all sandbox data)
  - Server configuration files
  - Agent state
  - All persistent data

### What's Restored

When you restore from backup, you get back:
- ✅ soul.md (personality) — Restored from database
- ✅ All conversations — Complete history restored
- ✅ Assistant configuration — All settings restored
- ✅ Sandbox state — Fully functional sandbox

### Why Docker Volume Backup is Critical

Since OpenShell stores everything in a **single SQLite database**, backing up the entire Docker volume ensures:
- Complete conversation history
- Unmodified assistant personality
- Exact sandbox state at backup time
- No data loss during migration/restore

### What Does NOT Get Backed Up

- Docker images — Can be re-pulled (too large)
- System packages — Reinstalled by setup.sh
- Temporary container layers — Not needed
- Build artifacts — Recreated on container start

---

## Credentials & Secrets Storage

### Where API Keys Are Stored

**In memory during operation:**
```bash
export NVIDIA_API_KEY="nvapi-..."
export TELEGRAM_BOT_TOKEN="123456:ABC..."
```

**On disk (encrypted by OS permissions):**
```bash
~/.nemoclaw/credentials.json (mode 600 - read-only by owner)
```

**File format:**
```json
{
  "NVIDIA_API_KEY": "nvapi-...",
  "TELEGRAM_BOT_TOKEN": "123456:ABC...",
  "GITHUB_TOKEN": "ghp_..." (optional)
}
```

### Security

- ✅ File permissions: `600` (only root can read)
- ✅ Backed up with restricted permissions
- ✅ Never logged or exposed in output
- ⚠️ Included in backups - protect backup files!

**When backing up:** Backups contain credentials. Treat backup files as secrets!

```bash
# Backup file permissions
ls -la /srv/nemoclaw/backups/
# Should show: -rw------- (600 permissions)
```

---

## Conversation History & Context

### Where Conversation Data Lives

**In the OpenShell database (SQLite):**
```
Docker Volume: openshell-cluster-nemoclaw
└── storage/pvc-*/openshell.db    # SQLite database containing:
    ├── All conversation messages
    ├── User/assistant message pairs
    ├── Timestamps and metadata
    └── Complete conversation context
```

**The database is backed up as:**
```bash
/var/lib/docker/volumes/openshell-cluster-nemoclaw/_data/storage/pvc-*/openshell.db
```

### Example: What a Conversation Looks Like Inside openshell.db

When you chat with your assistant, messages are stored in the SQLite database:

```json
{
  "messages": [
    {
      "role": "user",
      "content": "Hello, what's your name?"
    },
    {
      "role": "assistant",
      "content": "I'm your AI assistant..."
    }
  ],
  "metadata": {
    "created": "2026-03-22T16:00:00Z",
    "last_updated": "2026-03-22T16:30:00Z"
  }
}
```

### How It's Backed Up

1. **Daily automatic backup** (2:00 AM UTC):
   ```bash
   bash scripts/backup.sh
   # Runs daily via cron job
   ```

2. **Backup includes sandbox state:**
   ```
   nemoclaw-backup-2026-03-22-14-30-00.tar.gz
   └── nemoclaw-data/
       └── config/
           └── sandboxes/my-assistant/
               └── .openclaw/context.json  ✓ Included
   ```

3. **Conversation history persists:**
   - When you restore, all previous conversations come back
   - soul.md (personality) is restored too
   - No need to retrain or reconfigure

---

## Soul.md (Assistant Personality)

### What is soul.md?

**Your assistant's personality/instructions stored in OpenShell database:**
```
Docker Volume: openshell-cluster-nemoclaw
└── storage/pvc-*/openshell.db    # SQLite database containing soul.md
```

**What soul.md contains:**

Your assistant's complete personality definition - instructions, traits, behavior guidelines, and system prompts. When you set your assistant's personality, it's stored in the openshell.db database.

**Example content:**
```markdown
# My Personality

You are a helpful AI assistant named Claude.

Your key traits:
- Patient and thoughtful
- Clear and concise
- Curious and engaged

When responding:
- Explain concepts simply
- Ask clarifying questions
- Provide examples
```

### How It Persists

1. **Created during onboarding:** NemoClaw generates initial soul.md
2. **Lives in sandbox:** Can be edited inside the sandbox
3. **Backed up automatically:** Included in daily backups
4. **Restored on migration:** When you restore, soul.md comes back unchanged

### Editing soul.md

**Inside the sandbox:**
```bash
nemoclaw my-assistant connect
# Inside sandbox:
cat .openclaw/soul.md          # View it
nano .openclaw/soul.md         # Edit it
exit
```

**Changes are reflected immediately in the next conversation.**

---

## Automatic Daily Backups (Cron Job)

### How It Works

The `setup.sh` script automatically configures a **daily backup cron job** for the nemoclaw user.

**Default configuration (in `.env`):**
```bash
BACKUP_TIME="02:00"           # Run at 2:00 AM UTC daily
BACKUP_RETENTION_DAYS="30"    # Keep 30 days of backups
```

**The cron entry that gets created:**
```bash
00 02 * * * cd /root/nemoclaw-ai-assistant && bash scripts/backup.sh >> /var/log/nemoclaw-backup.log 2>&1
```

This runs every day at 2:00 AM UTC and logs to `/var/log/nemoclaw-backup.log`.

### Verify Cron Job is Set Up

```bash
# List nemoclaw user's cron jobs
crontab -u nemoclaw -l

# Should show something like:
# 00 02 * * * cd /root/nemoclaw-ai-assistant && bash scripts/backup.sh >> /var/log/nemoclaw-backup.log 2>&1

# Check cron daemon is running
systemctl status cron
# Should show: active (running)

# View backup execution logs
tail -f /var/log/nemoclaw-backup.log

# Check when last backup actually ran
ls -lt /srv/nemoclaw/backups/ | head -3
# Shows most recent backup files
```

### Configure Backup Schedule

**To change backup time:**

1. Edit `.env`:
```bash
BACKUP_TIME="03:00"  # Change to 3:00 AM UTC
```

2. Re-run setup (safe - idempotent):
```bash
bash scripts/setup.sh
```

The cron job will be updated automatically.

### Disable Automatic Backups

If you want to disable automatic backups and do manual backups only:

```bash
# Edit nemoclaw user's crontab
crontab -u nemoclaw -e

# Delete the backup.sh line and save
# Manual backups still work: bash scripts/backup.sh
```

### Manual Backups Anytime

Even with automatic backups, you can create manual backups anytime:

```bash
# Create backup immediately
bash scripts/backup.sh

# Manual backup with custom retention
bash scripts/backup.sh --retention 90

# Skip automatic cleanup
bash scripts/backup.sh --no-cleanup
```

---

## Migration & Restoration Workflow

### Scenario 1: Move to New VPS

**Step 1: Backup on old VPS**
```bash
bash scripts/backup.sh
# Creates: /srv/nemoclaw/backups/nemoclaw-backup-YYYY-MM-DD-HH-MM-SS.tar.gz
```

**Step 2: Copy backup to new VPS**
```bash
# On old VPS
scp /srv/nemoclaw/backups/nemoclaw-backup-*.tar.gz newvps:/tmp/

# Or download locally
scp -r nemoclaw@oldvps:/srv/nemoclaw/backups ~/backups-nemoclaw
```

**Step 3: Setup new VPS**
```bash
# New VPS
bash scripts/setup.sh
```

**Step 4: Restore backup**
```bash
# Copy backup to new VPS
cp /tmp/nemoclaw-backup-*.tar.gz /srv/nemoclaw/backups/

# Restore
bash scripts/restore.sh nemoclaw-backup-YYYY-MM-DD-HH-MM-SS.tar.gz
```

**Step 5: Verify**
```bash
nemoclaw list                      # Sandbox is back
nemoclaw my-assistant status       # Sandbox is Ready
nemoclaw my-assistant connect      # Connect to it
# Inside: cat .openclaw/soul.md    # soul.md is restored!
```

**Result:** 
- ✅ All conversations restored
- ✅ soul.md (personality) restored
- ✅ API keys and credentials restored
- ✅ Models and configuration restored

### Scenario 2: Local Restore on Same VPS

**Step 1: Backup (creates daily automatically)**
```bash
# Automatic daily at 2:00 AM UTC, or manual:
bash scripts/backup.sh
```

**Step 2: List available backups**
```bash
bash scripts/backup.sh --list
# Shows:
# /srv/nemoclaw/backups/nemoclaw-backup-2026-03-22-14-30-00.tar.gz
# /srv/nemoclaw/backups/nemoclaw-backup-2026-03-21-02-00-00.tar.gz
# ...
```

**Step 3: Destroy and restore**
```bash
# Destroy current sandbox
nemoclaw my-assistant destroy --yes

# Restore from backup
bash scripts/restore.sh nemoclaw-backup-2026-03-22-14-30-00.tar.gz

# Verify
nemoclaw list
nemoclaw my-assistant connect
```

**Result:**
- ✅ Assistant restored to that point in time
- ✅ All conversations up to backup date are back
- ✅ soul.md unchanged

---

## Data Retention & Cleanup

### Automatic Cleanup

**Retention policy (configured in `.env`):**
```bash
BACKUP_RETENTION_DAYS="30"
```

**Behavior:**
- Backups older than 30 days are deleted automatically
- Latest backups are always kept
- Manual backups can be preserved by moving them elsewhere

**To keep old backups:**
```bash
# Copy to cloud storage, external disk, etc.
cp /srv/nemoclaw/backups/nemoclaw-backup-2026-01-15-*.tar.gz ~/my-backups/
```

### Manual Cleanup

```bash
# Delete specific backup
rm /srv/nemoclaw/backups/nemoclaw-backup-2026-03-01-*.tar.gz

# Delete all but latest 10
ls -t /srv/nemoclaw/backups/*.tar.gz | tail -n +11 | xargs rm

# Disable automatic cleanup
bash scripts/backup.sh --no-cleanup
```

---

## Disaster Recovery Checklist

**Before something goes wrong:**

- [ ] Backup created: `bash scripts/backup.sh`
- [ ] Backup copied offsite: `scp <backup> cloud:~/`
- [ ] Backup tested (restore locally): `bash scripts/restore.sh <backup>`
- [ ] Credentials saved securely: `cat ~/.nemoclaw/credentials.json > ~/secure-location/`

**If disaster happens:**

1. **New VPS/machine:** Follow "Scenario 1: Move to New VPS" above
2. **Same VPS restore:** Follow "Scenario 2: Local Restore" above
3. **Lost credentials:** Recreate in `~/.nemoclaw/credentials.json`
4. **Lost backups:** Recreate sandbox with `nemoclaw onboard`

---

## Storage Size Estimates

**Typical storage usage:**

```
/srv/nemoclaw/
├── config/          ~10 MB   (sandboxes, policies)
├── logs/            ~500 MB  (growing over time)
└── backups/         ~20 GB   (30 days of daily backups)

Total: ~30-40 GB for active deployment + backups
```

**To check current usage:**
```bash
du -sh /srv/nemoclaw/
du -sh /srv/nemoclaw/*
```

**To free space:**
```bash
# Delete old models
docker compose exec ollama ollama rm mistral

# Delete old backups
bash scripts/backup.sh --no-cleanup
rm /srv/nemoclaw/backups/nemoclaw-backup-2026-01-*.tar.gz

# Clean Docker
docker system prune -a -f
```

---

## Important Notes

### Backup Security

⚠️ **Backups contain credentials!**
- Treat backup files as secrets
- Use encrypted storage for offsite backups
- Restrict file permissions: `chmod 600 backup.tar.gz`
- Consider encrypting before uploading to cloud

### Conversation Privacy

- All conversations stored locally on your VPS
- Not sent to NVIDIA (only inference requests go to NVIDIA API)
- Backup files contain full conversation history
- Restore backups only on trusted systems


---

## FAQ

**Q: If I lose `/srv/nemoclaw/`, can I recover?**

A: If backup is offsite, yes - restore from backup. If no backup, all conversations and config are lost, but you can recreate with `nemoclaw onboard`.

**Q: Does soul.md backup automatically?**

A: Yes! It's inside the OpenShell sandbox state, which is backed up daily.

**Q: Can I edit soul.md and keep changes?**

A: Yes, edits are persistent in the sandbox. Changes persist across backups and restores.

**Q: What if I restore an old backup - do I lose recent conversations?**

A: Yes, you revert to that point in time. Keep recent backups accessible for this reason.

**Q: Are credentials backed up?**

A: Yes, `credentials.json` is backed up. Treat backups as secrets!

**Q: How often should I backup?**

A: Daily (automatic). Manual backup anytime before major changes.

**Q: Can I move `/srv/nemoclaw/` to another drive?**

A: Yes, but update paths in `~/.nemoclaw/config/` and cron jobs. Better: use `bash scripts/backup.sh` and restore on new location.