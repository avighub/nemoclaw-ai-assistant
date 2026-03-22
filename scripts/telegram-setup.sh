#!/bin/bash

##############################################################################
# NemoClaw Telegram Bot Setup Script
#
# Automates Telegram bot integration for NemoClaw
#
# Steps:
#   1. Prompts for Telegram bot token
#   2. Finds NemoClaw installation path
#   3. Sets up environment variables
#   4. Starts Telegram bridge process
#   5. Verifies connection
#
# Usage: bash scripts/telegram-setup.sh [--help]
##############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
NEMOCLAW_USER="${NEMOCLAW_USER:-nemoclaw}"
SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"
LOG_DIR="/srv/nemoclaw/logs"
TELEGRAM_BRIDGE_LOG="$LOG_DIR/telegram-bridge.log"

##############################################################################
# Helper Functions
##############################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

usage() {
    cat << EOF
Usage: bash scripts/telegram-setup.sh [OPTIONS]

Automates Telegram bot integration with NemoClaw.

Prerequisites:
  1. Telegram bot created via @BotFather
  2. NemoClaw already installed and running
  3. NVIDIA API key configured

Options:
  --help                 Show this help message
  --token TOKEN          Provide bot token directly (non-interactive)
  --sandbox NAME         Sandbox name (default: my-assistant)
  --stop                 Stop Telegram bridge
  --restart              Restart Telegram bridge
  --logs                 Show Telegram bridge logs
  --verbose              Enable verbose output

Quick Start:
  bash scripts/telegram-setup.sh

Examples:
  bash scripts/telegram-setup.sh --token 123456:ABC-DEF1234
  bash scripts/telegram-setup.sh --logs
  bash scripts/telegram-setup.sh --stop
EOF
    exit 0
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running as root or correct user
    if [[ $EUID -ne 0 ]] && [[ $(whoami) != "$NEMOCLAW_USER" ]]; then
        log_error "Run as root or $NEMOCLAW_USER user"
        exit 1
    fi
    
    # Check nemoclaw installed
    if ! command -v nemoclaw &> /dev/null; then
        log_error "nemoclaw not found - ensure setup.sh completed and official installer ran"
        exit 1
    fi
    
    # Check Node.js
    if ! command -v node &> /dev/null; then
        log_error "node not found"
        exit 1
    fi
    
    log_success "Prerequisites met"
}

# Prompt for bot token
prompt_bot_token() {
    if [[ -n "${BOT_TOKEN:-}" ]]; then
        return 0  # Token already provided
    fi
    
    echo ""
    echo -e "${YELLOW}Telegram Bot Setup${NC}"
    echo ""
    echo "To create a bot:"
    echo "  1. Open Telegram and chat with @BotFather"
    echo "  2. Send /newbot"
    echo "  3. Follow prompts"
    echo "  4. Copy the bot token (e.g., 123456:ABC-DEF1234ghIkl)"
    echo ""
    
    read -p "Enter your Telegram bot token: " BOT_TOKEN
    
    if [[ -z "$BOT_TOKEN" ]]; then
        log_error "Bot token cannot be empty"
        exit 1
    fi
    
    # Basic validation
    if [[ ! "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        log_warn "Token format looks incorrect, but continuing..."
    fi
}

# Find NemoClaw installation
find_nemoclaw_path() {
    log_info "Finding NemoClaw installation..."
    
    # Try npm global path
    if command -v npm &> /dev/null; then
        NEMOCLAW_PATH="$(npm root -g 2>/dev/null)/../nemoclaw"
        if [[ -f "$NEMOCLAW_PATH/package.json" ]]; then
            log_success "Found at: $NEMOCLAW_PATH"
            return 0
        fi
    fi
    
    # Try common paths
    for path in /usr/local/lib/node_modules/nemoclaw /usr/lib/node_modules/nemoclaw ~/.nvm/versions/node/*/lib/node_modules/nemoclaw; do
        if [[ -f "$path/package.json" ]]; then
            NEMOCLAW_PATH="$path"
            log_success "Found at: $NEMOCLAW_PATH"
            return 0
        fi
    done
    
    log_error "Could not find NemoClaw installation"
    log_info "Try: npm root -g to find Node global modules"
    exit 1
}

# Create environment file
create_env_file() {
    log_info "Creating environment configuration..."
    
    local env_file="/home/$NEMOCLAW_USER/.nemoclaw/telegram.env"
    mkdir -p "$(dirname "$env_file")"
    
    cat > "$env_file" << EOF
# NemoClaw Telegram Bot Configuration
TELEGRAM_BOT_TOKEN=$BOT_TOKEN
SANDBOX_NAME=$SANDBOX_NAME
NEMOCLAW_PATH=$NEMOCLAW_PATH

# Optional: Custom settings
# LOG_LEVEL=debug
# MESSAGE_TIMEOUT=30
EOF

    chown $NEMOCLAW_USER:$NEMOCLAW_USER "$env_file"
    chmod 600 "$env_file"  # Restrict permissions (contains token)
    
    log_success "Environment file created: $env_file"
}

# Create telegram bridge wrapper script
create_bridge_wrapper() {
    log_info "Creating Telegram bridge startup script..."
    
    local wrapper="/home/$NEMOCLAW_USER/.nemoclaw/start-telegram-bridge.sh"
    mkdir -p "$(dirname "$wrapper")"
    
    cat > "$wrapper" << 'BRIDGE_SCRIPT'
#!/bin/bash
set -euo pipefail

# Load environment
if [[ -f ~/.nemoclaw/telegram.env ]]; then
    source ~/.nemoclaw/telegram.env
else
    echo "Error: ~/.nemoclaw/telegram.env not found"
    exit 1
fi

# Ensure log directory
mkdir -p /srv/nemoclaw/logs

# Find telegram-bridge script
BRIDGE_SCRIPT="$NEMOCLAW_PATH/scripts/telegram-bridge.js"
if [[ ! -f "$BRIDGE_SCRIPT" ]]; then
    # Try alternative paths
    BRIDGE_SCRIPT=$(find "$NEMOCLAW_PATH" -name "telegram-bridge.js" 2>/dev/null | head -1)
    if [[ -z "$BRIDGE_SCRIPT" ]]; then
        echo "Error: telegram-bridge.js not found"
        exit 1
    fi
fi

# Start bridge
export TELEGRAM_BOT_TOKEN
export SANDBOX_NAME

echo "Starting Telegram bridge..."
echo "Bot token: ${TELEGRAM_BOT_TOKEN:0:10}****"
echo "Sandbox: $SANDBOX_NAME"
echo "Log: /srv/nemoclaw/logs/telegram-bridge.log"
echo ""

node "$BRIDGE_SCRIPT" 2>&1 | tee -a /srv/nemoclaw/logs/telegram-bridge.log
BRIDGE_SCRIPT
    
    chmod +x "$wrapper"
    chown $NEMOCLAW_USER:$NEMOCLAW_USER "$wrapper"
    
    log_success "Bridge wrapper created: $wrapper"
}

# Create systemd service for Telegram bridge
create_systemd_service() {
    log_info "Creating systemd service for Telegram bridge..."
    
    local service_file="/etc/systemd/system/nemoclaw-telegram.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=NemoClaw Telegram Bridge
Documentation=https://docs.nvidia.com/nemoclaw/
After=nemoclaw.service
Wants=nemoclaw.service

[Service]
Type=simple
User=$NEMOCLAW_USER
Group=$NEMOCLAW_USER
WorkingDirectory=/home/$NEMOCLAW_USER

ExecStart=/home/$NEMOCLAW_USER/.nemoclaw/start-telegram-bridge.sh

Restart=on-failure
RestartSec=10

StandardOutput=journal
StandardError=journal
SyslogIdentifier=nemoclaw-telegram

Environment="HOME=/home/$NEMOCLAW_USER"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    
    log_success "Systemd service created: $service_file"
}

# Start Telegram bridge
start_telegram_bridge() {
    log_info "Starting Telegram bridge..."
    
    systemctl enable nemoclaw-telegram.service
    systemctl start nemoclaw-telegram.service
    
    sleep 2
    
    if systemctl is-active nemoclaw-telegram.service &> /dev/null; then
        log_success "Telegram bridge started successfully"
        return 0
    else
        log_error "Failed to start Telegram bridge"
        log_info "Check logs: systemctl status nemoclaw-telegram.service"
        return 1
    fi
}

# Stop Telegram bridge
stop_telegram_bridge() {
    log_info "Stopping Telegram bridge..."
    
    if systemctl is-active nemoclaw-telegram.service &> /dev/null; then
        systemctl stop nemoclaw-telegram.service
        log_success "Telegram bridge stopped"
    else
        log_warn "Telegram bridge is not running"
    fi
}

# Restart Telegram bridge
restart_telegram_bridge() {
    log_info "Restarting Telegram bridge..."
    
    systemctl restart nemoclaw-telegram.service
    sleep 2
    
    if systemctl is-active nemoclaw-telegram.service &> /dev/null; then
        log_success "Telegram bridge restarted successfully"
        return 0
    else
        log_error "Failed to restart Telegram bridge"
        return 1
    fi
}

# Show logs
show_logs() {
    log_info "Telegram bridge logs (press Ctrl+C to exit):"
    echo ""
    journalctl -u nemoclaw-telegram.service -f
}

# Verify setup
verify_setup() {
    log_info "Verifying Telegram setup..."
    
    echo ""
    echo -e "${BLUE}Configuration:${NC}"
    if [[ -f /home/$NEMOCLAW_USER/.nemoclaw/telegram.env ]]; then
        echo "  ✓ Environment file created"
        echo "    Token: ${BOT_TOKEN:0:10}****"
        echo "    Sandbox: $SANDBOX_NAME"
    else
        echo "  ✗ Environment file not found"
    fi
    
    echo ""
    echo -e "${BLUE}Service Status:${NC}"
    if systemctl is-active nemoclaw-telegram.service &> /dev/null; then
        echo "  ✓ Telegram bridge is running"
        systemctl status nemoclaw-telegram.service --no-pager | head -5
    else
        echo "  ✗ Telegram bridge is not running"
    fi
    
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "  1. Open Telegram and find your bot (search by name)"
    echo "  2. Send a message: 'hello'"
    echo "  3. Check logs: bash scripts/telegram-setup.sh --logs"
    echo ""
}

# Print summary
print_summary() {
    cat << EOF

$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )
$( echo -e "${GREEN}Telegram Bot Setup Complete!${NC}" )
$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )

Configuration Saved:
  ✓ Bot token stored safely in ~/.nemoclaw/telegram.env
  ✓ Systemd service created (auto-start on reboot)
  ✓ Telegram bridge running

To Use:
  1. Open Telegram and find your bot
  2. Start messaging - your bot will forward to NemoClaw sandbox
  3. Messages are processed by: $SANDBOX_NAME

Useful Commands:
  View logs:        bash scripts/telegram-setup.sh --logs
  Stop bridge:      bash scripts/telegram-setup.sh --stop
  Restart bridge:   bash scripts/telegram-setup.sh --restart
  Check status:     systemctl status nemoclaw-telegram.service

Troubleshooting:
  • No response in Telegram? Check logs: systemctl journalctl -u nemoclaw-telegram -f
  • Bot token wrong? Edit: ~/.nemoclaw/telegram.env
  • Bridge crashed? Restart: bash scripts/telegram-setup.sh --restart

$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )
EOF
}

##############################################################################
# Main Setup Flow
##############################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help) usage ;;
            --token) BOT_TOKEN="$2"; shift 2 ;;
            --sandbox) SANDBOX_NAME="$2"; shift 2 ;;
            --stop) stop_telegram_bridge; exit 0 ;;
            --restart) restart_telegram_bridge; exit 0 ;;
            --logs) show_logs; exit 0 ;;
            --verbose) set -x; shift ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
    
    log_info "═══════════════════════════════════════════════════════════"
    log_info "NemoClaw Telegram Bot Setup"
    log_info "═══════════════════════════════════════════════════════════"
    
    # Run setup steps
    check_prerequisites
    prompt_bot_token
    find_nemoclaw_path
    create_env_file
    create_bridge_wrapper
    create_systemd_service
    start_telegram_bridge
    verify_setup
    print_summary
    
    log_success "Telegram setup completed!"
}

# Run main
main "$@"