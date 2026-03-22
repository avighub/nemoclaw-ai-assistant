# NemoClaw Troubleshooting Guide

Solutions for common issues during setup, deployment, and operation.

## Setup & Onboarding Issues

### Onboarding Fails at Step [6/7] - "sandbox not found"

**Error:**
```
[6/7] Setting up OpenClaw inside sandbox
Error: × status: NotFound, message: "sandbox not found"
Command failed (exit 1): openshell sandbox connect "my-assistant"
```

**Causes:**
1. `NVIDIA_API_KEY` not set in environment
2. Sandbox registry out of sync with OpenShell
3. NVIDIA API connectivity issue

**Solutions:**

**Step 1: Verify API Key is in Environment**
```bash
# Check if API key is set
echo $NVIDIA_API_KEY

# If empty, source .env file
source .env
echo $NVIDIA_API_KEY

# Should output your API key (first 10 chars: nvapi-...)
```

**Step 2: Clean Up Failed Registry**
```bash
# Remove the failed sandbox from registry
rm ~/.nemoclaw/sandboxes.json

# Verify it's gone
ls ~/.nemoclaw/
```

**Step 3: Retry Onboarding**
```bash
# Make sure API key is still in environment
source .env

# Restart onboarding
nemoclaw onboard
```

**Step 4: Verify Sandbox Creation**
```bash
# Check NemoClaw sees the sandbox
nemoclaw list

# Check OpenShell actually created it
openshell sandbox list

# Both should show "my-assistant"
```

If both show the sandbox, onboarding succeeded! Continue to next section.

---

### Onboarding Completes but Sandbox Not Responding

**Symptom:** `nemoclaw list` shows sandbox, but `openshell sandbox list` shows nothing.

**Cause:** Sandbox registered but not actually created in OpenShell.

**Fix:**
```bash
# Remove stale registry entry
rm ~/.nemoclaw/sandboxes.json

# Ensure OpenShell gateway is running
ps aux | grep openshell | grep -v grep
# Should show: openshell-server --port 8080 ...

# If not running, restart OpenShell
systemctl restart openshell.service

# Retry onboarding
source .env
nemoclaw onboard
```

---

## Telegram Bridge Issues

### Telegram Bridge Won't Start

**Error:**
```
[services] TELEGRAM_BOT_TOKEN not set — Telegram bridge will not start.
```

**Cause:** Environment variable not set. `nemoclaw start` reads from environment, not from credentials file.

**Fix:**
```bash
# Extract token from credentials file
export TELEGRAM_BOT_TOKEN=$(grep -o '"TELEGRAM_BOT_TOKEN":"[^"]*"' ~/.nemoclaw/credentials.json | cut -d'"' -f4)

# Verify it's set
echo $TELEGRAM_BOT_TOKEN

# Now start services
nemoclaw start
```

You should see:
```
telegram-bridge started (PID xxxxx)
Telegram:    bridge running
```

---

### Telegram Bot Not Responding

**Symptom:** Send message to bot in Telegram, no response.

**Causes:**
1. Bridge not running
2. Bot token is wrong
3. Policy not added to sandbox

**Diagnostics:**
```bash
# Check if bridge is running
nemoclaw status
# Should show: Telegram: bridge running

# Check bridge logs
journalctl -u nemoclaw-telegram -f 2>/dev/null || \
  tail -f ~/.nemoclaw/telegram-bridge.log 2>/dev/null || \
  echo "No systemd service or log file found"

# Verify policy is applied
nemoclaw my-assistant policy-list
# Should show "● telegram" (with dot, meaning applied)
```

**Fix:**
```bash
# Verify token is correct
cat ~/.nemoclaw/credentials.json | grep TELEGRAM_BOT_TOKEN

# Re-export and restart
export TELEGRAM_BOT_TOKEN=$(grep -o '"TELEGRAM_BOT_TOKEN":"[^"]*"' ~/.nemoclaw/credentials.json | cut -d'"' -f4)
nemoclaw stop
nemoclaw start

# Wait 5 seconds and try again
sleep 5

# Test with Telegram
# Send: hello
```

---

## API Response Issues

### NVIDIA API Slow or Not Responding

**Symptom:** 
- Queries hang for 30+ seconds
- Free tier works for "hi" but fails on complex queries
- openclaw tui starts but doesn't respond

**Important:** NVIDIA free tier has limitations:
- 40 requests/minute rate limit
- Smaller context window
- May timeout on large/complex queries

**Symptoms of Free Tier Limits:**
```
No output for 1+ minute
Timeout errors
Works for simple queries but fails for complex ones
```

**Solution: Use Local Ollama Instead**

```bash
# Start Ollama
docker compose up -d ollama

# Pull a fast model
docker compose exec ollama ollama pull mistral

# Verify it works
curl http://localhost:11434/api/generate -d '{"model":"mistral","prompt":"hi"}'

# Configure NemoClaw to use Ollama (in sandbox)
nemoclaw my-assistant connect
# Inside sandbox:
openclaw config set model mistral
openclaw config set provider ollama
exit

# Restart and test
nemoclaw my-assistant connect
openclaw tui
# Type: hello
```

Ollama will be much faster and more reliable than NVIDIA free tier.

---

### "Missing API Keys" Warning in openclaw tui

**Warning:**
```
🦞 OpenClaw 2026.3.11 — I don't judge, but your missing API keys are absolutely judging you.
```

**Cause:** Some policies (pypi, npm, github) were added but API keys not provided.

**This is non-critical** — the sandbox still works, but those specific integrations won't work.

**Fix (Optional):**
```bash
# To use npm registry, get GitHub token and add:
export GITHUB_TOKEN="your-github-token"
nemoclaw my-assistant policy-add
# Select: github

# To use pypi, ensure Python credentials are set
# (Usually automatic on Linux/Mac)
```

---

## Sandbox Connection Issues

### Can't Connect to Sandbox

**Error:**
```
Command failed: openshell sandbox connect "my-assistant"
```

**Cause:** Sandbox not in "Ready" state.

**Diagnostic:**
```bash
# Check sandbox state
openshell sandbox list
# Should show Phase: Ready

# If not Ready (e.g., Pending, Error):
openshell sandbox get my-assistant
```

**Fix:**
```bash
# Wait for sandbox to be Ready (can take 1-2 minutes)
watch -n 2 "openshell sandbox list"
# Press Ctrl+C when Phase shows "Ready"

# Then try connecting
nemoclaw my-assistant connect
```

---

## Service Status & Debugging

### Check Everything at Once

```bash
# Overall status
nemoclaw status

# Detailed sandbox info
nemoclaw my-assistant status

# View all logs
nemoclaw debug

# Save diagnostics for GitHub issues
nemoclaw debug --output /tmp/nemoclaw-debug.tar.gz
```

### View Logs

**NemoClaw logs:**
```bash
journalctl -u nemoclaw.service -f
```

**OpenShell logs:**
```bash
journalctl -u openshell.service -f
```

**Telegram bridge logs:**
```bash
journalctl -u nemoclaw-telegram.service -f 2>/dev/null || \
  tail -f ~/.nemoclaw/telegram-bridge.log
```

**Docker services (Ollama, Prometheus, etc.):**
```bash
docker compose logs -f
```

---

## Common Workarounds

### Restart Everything Fresh

```bash
# Stop services
nemoclaw stop
systemctl stop openshell.service

# Wait
sleep 5

# Start services
systemctl start openshell.service
sleep 5

nemoclaw start
```

### Remove and Recreate Sandbox

```bash
# Backup first
bash scripts/backup.sh

# Remove sandbox
nemoclaw my-assistant destroy --yes

# Wait for cleanup
sleep 5

# Recreate sandbox
nemoclaw onboard
```

### Reset All NemoClaw State

```bash
# Backup everything
bash scripts/backup.sh

# Stop services
nemoclaw stop

# Remove NemoClaw config
rm -rf ~/.nemoclaw

# Remove sandbox
openshell sandbox delete my-assistant 2>/dev/null || true

# Restart setup
source .env
nemoclaw onboard
```

---

## Getting Help

If issues persist:

1. **Collect diagnostics:**
   ```bash
   nemoclaw debug --output ~/nemoclaw-debug.tar.gz
   ```

2. **Check logs:**
   ```bash
   journalctl -u nemoclaw -n 100
   journalctl -u openshell -n 100
   ```

3. **Verify resources:**
   ```bash
   free -h
   df -h /
   ps aux | grep -E "openshell|nemoclaw|ollama"
   ```

4. **Post on NemoClaw Discord:** https://discord.gg/XFpfPv9Uvx
   - Include output from `nemoclaw debug`
   - Describe what you're trying to do
   - Show error messages

---

## FAQ

**Q: Is NVIDIA free tier enough?**

A: For simple queries yes, but it's slow (30+ sec responses) and limited context. Use Ollama for reliable, fast responses.

**Q: Can I use my own local LLM?**

A: Yes! Ollama is included in docker-compose.yml. See "NVIDIA API Slow" section above.

**Q: Why does Telegram take so long to respond?**

A: Messages go through OpenShell sandbox → NVIDIA API → response. That's 3 hops. Use Ollama for faster responses.

**Q: Can I use OpenRouter instead of NVIDIA?**

A: NemoClaw is built for NVIDIA APIs. For other providers, you'd need to modify source code or use a different tool.

**Q: How do I know if setup succeeded?**

A: Run these commands — all should show success:
```bash
nemoclaw list              # Shows sandbox
openshell sandbox list     # Shows sandbox as Ready
nemoclaw my-assistant status  # Shows details
nemoclaw start && nemoclaw status  # Shows services running
# Send message in Telegram - gets response
```