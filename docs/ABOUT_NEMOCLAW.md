# About NemoClaw

NemoClaw is NVIDIA's management and orchestration layer for running production-grade AI agents using OpenClaw and OpenShell.

- **NemoClaw** = Sandbox Operator — manages lifecycle, policies, services (runs on the host)
- **OpenClaw** = Chat Client — your interface to talk to the assistant (runs inside the sandbox)
- **OpenShell** = Sandbox Runtime — provides isolation and security (the container environment)

They're complementary: NemoClaw orchestrates, OpenClaw interacts, OpenShell isolates. Think of it like Docker Compose (NemoClaw) vs Docker (OpenShell) vs the app running inside (OpenClaw).

---

## Architecture

```
WITH NemoClaw (What NVIDIA Built):
┌─────────────────────────────────┐
│  NemoClaw (Management Layer)    │
│  - Create/destroy sandboxes     │
│  - Manage policies              │
│  - Orchestrate services         │
│  - Store credentials            │
│  - Multi-sandbox support        │
│  - Health monitoring            │
│  - Service integration          │
└─────────────────────────────────┘
         ↓ (delegates)
┌─────────────────────────────────┐
│  OpenClaw (Chat Interface)      │
│  - Interactive TUI              │
│  - Send messages                │
└─────────────────────────────────┘
         ↓
┌─────────────────────────────────┐
│  OpenShell Sandbox              │
│  - Isolated environment         │
│  - Runs the model               │
│  - Enforces policies            │
└─────────────────────────────────┘


WITHOUT NemoClaw (Just OpenClaw):
┌─────────────────────────────────┐
│  OpenClaw (Chat Interface)      │
│  - Interactive TUI only         │
│  - One sandbox hardcoded        │
│  - No policies                  │
│  - No external services         │
└─────────────────────────────────┘
         ↓
┌─────────────────────────────────┐
│  OpenShell Sandbox              │
│  - Isolated environment         │
│  - Runs the model               │
└─────────────────────────────────┘
```

---

## NemoClaw vs OpenClaw

| Aspect | NemoClaw | OpenClaw |
|--------|----------|----------|
| **Location** | Outside sandbox (host) | Inside sandbox |
| **Purpose** | Manage sandboxes, policies, services | Chat with the assistant |
| **Commands** | `nemoclaw <name> <action>` | `openclaw tui`, `openclaw agent` |
| **Runs as** | nemoclaw user | sandbox user |
| **Scope** | System-wide, multi-sandbox | Single sandbox only |

---

## Commands Reference

**NemoClaw (host — management):**
```bash
nemoclaw onboard                    # Create sandbox + API setup
nemoclaw list                       # List all sandboxes
nemoclaw my-assistant status        # Health check & NIM status
nemoclaw my-assistant logs --follow # Stream logs
nemoclaw my-assistant destroy       # Delete sandbox
nemoclaw my-assistant policy-add    # Control what the sandbox can access
nemoclaw my-assistant policy-list   # See applied policies
nemoclaw start                      # Start Telegram bridge, tunnel, etc.
nemoclaw stop                       # Stop services
nemoclaw debug                      # Collect diagnostics
```

**OpenClaw (inside sandbox — chat):**
```bash
nemoclaw my-assistant connect       # Enter the sandbox
sandbox@my-assistant:~$ openclaw tui              # Interactive chat
sandbox@my-assistant:~$ openclaw agent -m "hello" # Send a single message
```

---

## Real-World Flow

```bash
# 1. Create and configure the sandbox
nemoclaw onboard

# 2. Check it's ready
nemoclaw my-assistant status

# 3. Connect into the sandbox
nemoclaw my-assistant connect

# 4. Inside the sandbox — start chatting
sandbox@my-assistant:~$ openclaw tui

>> Hello, what's your name?
<< I'm your AI assistant...

# 5. Exit chat, then exit sandbox
exit   # exits OpenClaw (still in sandbox)
exit   # exits sandbox (back to host)

# 6. Back on host — management tasks
nemoclaw my-assistant logs
nemoclaw my-assistant destroy
```

---

## How NemoClaw Extends OpenClaw

The following capabilities are added by NemoClaw on top of bare OpenClaw (from `nemoclaw.js` source):

### Multi-Sandbox Management
```javascript
// NemoClaw tracks multiple sandboxes in a registry
const { sandboxes, defaultSandbox } = registry.listSandboxes();
for (const sb of sandboxes) {
  console.log(`${sb.name}: ${sb.model} (${sb.provider})`);
}
// OpenClaw alone: one hardcoded sandbox only
```

### Policy Enforcement
```javascript
// NemoClaw applies preset security policies per sandbox
policies.listPresets();  // discord, telegram, github, npm, pypi, etc.
policies.applyPreset(sandboxName, "telegram");
policies.getAppliedPresets(sandboxName);
// OpenClaw alone: no policy system, everything is open
```

### Credential Management
```javascript
// NemoClaw centralizes credentials across all sandboxes
getCredential("TELEGRAM_BOT_TOKEN");
getCredential("GITHUB_TOKEN");
getCredential("SLACK_BOT_TOKEN");
// Stored in ~/.nemoclaw/credentials.json
// OpenClaw alone: no credential handling
```

### External Service Integration
```javascript
// NemoClaw injects credentials into services and starts them
const tgToken = getCredential("TELEGRAM_BOT_TOKEN");
if (tgToken) envLines.push(`TELEGRAM_BOT_TOKEN=${shellQuote(tgToken)}`);
// nemoclaw start → launches Telegram bridge, cloudflared tunnel, etc.
// OpenClaw alone: cannot manage external services
```

---

## Why NVIDIA Built NemoClaw

OpenClaw alone is a chat toy. NemoClaw makes it production-ready:

1. **Multi-agent systems** — run 10 AI assistants (support, coding, research) each with different configs
2. **Security boundaries** — Agent A can access GitHub but not npm; Agent B can access Slack but not Discord
3. **External integrations** — Telegram bot, public tunnels, webhooks — all managed with one command
4. **Monitoring & ops** — health checks, log streaming, diagnostics built in
5. **Abstraction** — hides low-level OpenShell complexity behind a clean CLI (like Docker Compose over Docker)
```

---

## Summary

**OpenClaw** = "I want to chat with an AI"
**NemoClaw** = "I want to deploy, manage, and secure multiple AI agents in production"

NVIDIA built NemoClaw because:
- ✅ Production deployments need more than just chat
- ✅ Security policies need enforcement
- ✅ Multi-agent systems need orchestration
- ✅ External services need integration
- ✅ You need monitoring/debugging
- ✅ Enterprise customers need this infrastructure

It's the difference between:
- A chat toy (OpenClaw alone)
- vs. A production-grade AI agent platform (NemoClaw + OpenClaw + OpenShell)