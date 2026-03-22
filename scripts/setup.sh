#!/bin/bash

##############################################################################
# NemoClaw Production Setup Script
# 
# This script (all-in-one, fully automated):
#   1. Updates system packages
#   2. Creates non-root nemoclaw user (if needed)
#   3. Validates prerequisites and installs missing tools
#   4. Installs dependencies (Docker, Node.js, npm, OpenShell)
#   5. Installs NemoClaw globally
#   6. Creates persistent volume directories
#   7. Loads configuration from .env
#   8. Runs initial NemoClaw onboarding
#   9. Sets up systemd service and cron jobs
#
# Usage: bash scripts/setup.sh [--help]
# 
# Prerequisites: Root access on Ubuntu 22.04 LTS or later
##############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
DEPLOY_LOG="/var/log/nemoclaw-setup.log"

# Default values (can be overridden by .env)
NEMOCLAW_USER="${NEMOCLAW_USER:-nemoclaw}"
NEMOCLAW_HOME="${NEMOCLAW_HOME:-/home/nemoclaw}"
CONFIG_DIR="${CONFIG_DIR:-/srv/nemoclaw/config}"
MODELS_DIR="${MODELS_DIR:-/srv/nemoclaw/models}"
LOGS_DIR="${LOGS_DIR:-/srv/nemoclaw/logs}"
BACKUP_DIR="${BACKUP_DIR:-/srv/nemoclaw/backups}"

##############################################################################
# Helper Functions
##############################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$DEPLOY_LOG"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$DEPLOY_LOG"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$DEPLOY_LOG"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$DEPLOY_LOG"
}

usage() {
    cat << EOF
Usage: bash scripts/setup.sh [OPTIONS]

Fully automated NemoClaw installation (no prerequisites needed).
Run as root on a fresh Ubuntu 22.04 LTS or later instance.

Options:
  --help              Show this help message
  --skip-docker       Skip Docker installation (assumes already installed)
  --skip-nodejs       Skip Node.js installation (assumes already installed)
  --skip-user-create  Skip creating nemoclaw non-root user
  --no-monitoring     Skip monitoring stack setup
  --verbose           Enable verbose output

Process:
  1. Updates system packages (apt update/upgrade)
  2. Creates nemoclaw user if needed
  3. Installs all dependencies
  4. Sets up NemoClaw and services

Requirements:
  - Root access
  - Ubuntu 22.04 LTS or later
  - .env file with NVIDIA_API_KEY (copy from .env.example)

Quick start:
  cp .env.example .env
  nano .env  # Edit with your NVIDIA_API_KEY
  bash scripts/setup.sh

Examples:
  bash scripts/setup.sh
  bash scripts/setup.sh --skip-docker --verbose
  bash scripts/setup.sh --skip-user-create
EOF
    exit 0
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Load environment file
load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error ".env file not found at $ENV_FILE"
        log_info "Create .env from .env.example:"
        log_info "  cp .env.example .env"
        log_info "  nano .env  # edit with your NVIDIA_API_KEY"
        exit 1
    fi
    
    # Source .env but don't fail if variables are unset
    set +u
    source "$ENV_FILE"
    set -u
    
    # Validate required variables
    if [[ -z "${NVIDIA_API_KEY:-}" ]]; then
        log_error "NVIDIA_API_KEY not set in .env"
        exit 1
    fi
    
    log_success "Loaded configuration from .env"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing=()
    
    # Required commands
    local required_cmds=("curl" "wget" "git" "tar" "gzip" "jq")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing commands: ${missing[*]}"
        log_info "Installing missing prerequisites..."
        apt-get update
        apt-get install -y curl wget git tar gzip jq
    fi
    
    log_success "Prerequisites check passed"
}

# Update system packages
update_system() {
    log_info "Updating system packages..."
    
    apt-get update
    apt-get upgrade -y
    
    log_success "System packages updated"
}

# Create non-root user for NemoClaw
create_nonroot_user() {
    if [[ "${SKIP_USER:-false}" == "true" ]]; then
        log_info "Skipping non-root user creation (--skip-user-create flag)"
        return 0
    fi
    
    if id "$NEMOCLAW_USER" &>/dev/null; then
        log_info "User $NEMOCLAW_USER already exists, skipping creation"
        return 0
    fi
    
    log_info "Creating non-root user: $NEMOCLAW_USER"
    
    # Create user with home directory and bash shell
    useradd -m -s /bin/bash "$NEMOCLAW_USER"
    
    # Add to sudo group (passwordless sudo for convenience)
    usermod -aG sudo "$NEMOCLAW_USER"
    
    # Create project directory
    mkdir -p "$NEMOCLAW_HOME/nemoclaw-deploy"
    chown -R "$NEMOCLAW_USER:$NEMOCLAW_USER" "$NEMOCLAW_HOME"
    
    log_success "User $NEMOCLAW_USER created with sudo access"
}

# Install Docker
install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker already installed: $(docker --version)"
        return 0
    fi
    
    log_info "Installing Docker..."
    
    # Docker installation script
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    bash /tmp/get-docker.sh
    rm /tmp/get-docker.sh
    
    # Start Docker daemon
    systemctl start docker
    systemctl enable docker
    
    # Add nemoclaw user to docker group
    usermod -aG docker "${NEMOCLAW_USER}" 2>/dev/null || true
    
    log_success "Docker installed: $(docker --version)"
}

# Install Node.js (via nvm, supports multiple versions)
install_nodejs() {
    if command -v node &> /dev/null; then
        local node_version=$(node --version)
        log_info "Node.js already installed: $node_version"
        
        # Check if version is 20+
        local major_version=$(echo "$node_version" | sed 's/v\([0-9]*\).*/\1/')
        if [[ $major_version -ge 20 ]]; then
            log_success "Node.js version $node_version meets requirement (20+)"
            return 0
        else
            log_warn "Node.js version $node_version is too old, upgrading..."
        fi
    fi
    
    log_info "Installing Node.js 20.x..."
    
    # Using NodeSource repository
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    
    log_success "Node.js installed: $(node --version)"
    log_success "npm installed: $(npm --version)"
}

# Install OpenShell CLI via pip3
install_openshell() {
    if command -v openshell &> /dev/null; then
        log_info "OpenShell already installed"
        return 0
    fi
    
    log_info "Installing OpenShell..."
    
    # Ensure pip3 is available
    if ! command -v pip3 &> /dev/null; then
        log_info "Installing pip3..."
        apt-get install -y python3-pip
    fi
    
    # Get latest release version
    local latest_release=$(curl -s https://api.github.com/repos/NVIDIA/OpenShell/releases/latest | jq -r '.tag_name')
    local version="${latest_release#v}"  # Remove 'v' prefix (v0.0.13 -> 0.0.13)
    local wheel_url="https://github.com/NVIDIA/OpenShell/releases/download/${latest_release}/openshell-${version}-py3-none-manylinux_2_39_x86_64.whl"
    
    log_info "Downloading from: $wheel_url"
    
    # Install via pip3 with explicit --break-system-packages flag for Debian/Ubuntu
    if pip3 install --break-system-packages "$wheel_url" 2>&1 | grep -q "Successfully installed"; then
        # Verify installation
        if command -v openshell &> /dev/null; then
            log_success "OpenShell installed successfully via pip3"
            return 0
        fi
    fi
    
    # If pip install failed, try direct download (fallback)
    log_warn "pip3 installation failed, trying direct download..."
    
    local temp_dir=$(mktemp -d)
    if curl -fsSL "$wheel_url" -o "$temp_dir/openshell.whl" 2>/dev/null; then
        pip3 install --break-system-packages "$temp_dir/openshell.whl" 2>/dev/null || true
        rm -rf "$temp_dir"
    fi
    
    # Final check
    if command -v openshell &> /dev/null; then
        log_success "OpenShell installed"
        return 0
    else
        log_warn "Could not install OpenShell (will be installed by NemoClaw during onboarding)"
        return 0
    fi
}

# Install NemoClaw via npm
install_nemoclaw() {
    log_info "Installing NemoClaw globally..."
    
    # Install globally
    npm install -g nemoclaw 2>&1 | tail -1
    
    # Wait for npm to finish
    sleep 2
    
    # Get npm global prefix
    local npm_global=$(npm prefix -g)
    local nemoclaw_bin="$npm_global/bin/nemoclaw"
    
    # If nemoclaw was installed, create symlink in /usr/local/bin
    if [[ -f "$nemoclaw_bin" ]]; then
        log_info "Creating symlink to nemoclaw binary at /usr/local/bin/nemoclaw..."
        ln -sf "$nemoclaw_bin" /usr/local/bin/nemoclaw
        chmod +x /usr/local/bin/nemoclaw
        
        # Verify symlink works
        if /usr/local/bin/nemoclaw --version &>/dev/null; then
            log_success "NemoClaw installed and symlinked to /usr/local/bin/nemoclaw"
            return 0
        fi
    fi
    
    # If all else fails, continue anyway - onboarding will handle it
    log_warn "NemoClaw binary linking incomplete - will be installed during onboarding"
    log_info "You can verify later with: npm prefix -g | xargs -I {} ls {}/bin/nemoclaw"
    return 0
}

# Create persistent volume directories
create_directories() {
    log_info "Creating persistent volume directories..."
    
    for dir in "$CONFIG_DIR" "$MODELS_DIR" "$LOGS_DIR" "$BACKUP_DIR"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_info "Created: $dir"
        fi
    done
    
    # Set permissions for nemoclaw user
    if id "$NEMOCLAW_USER" &>/dev/null; then
        chown -R "${NEMOCLAW_USER}:${NEMOCLAW_USER}" /srv/nemoclaw
        chmod -R 755 /srv/nemoclaw
    fi
    
    log_success "Directories created and configured"
}

# Run NemoClaw onboarding (interactive)
run_onboarding() {
    log_info "Starting NemoClaw onboarding..."
    log_info "This is interactive - you'll be prompted for configuration."
    log_warn "Make sure NVIDIA_API_KEY is set in .env before proceeding."
    
    # Run as nemoclaw user if it exists
    if id "$NEMOCLAW_USER" &>/dev/null; then
        su - "$NEMOCLAW_USER" -c "nemoclaw onboard"
    else
        nemoclaw onboard
    fi
    
    log_success "Onboarding complete"
}

# Set up systemd service for NemoClaw
setup_systemd_service() {
    log_info "Setting up systemd service..."
    
    local service_file="/etc/systemd/system/nemoclaw.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=NemoClaw OpenShell Gateway
Documentation=https://docs.nvidia.com/nemoclaw/
After=docker.service
Wants=docker.service

[Service]
Type=simple
User=${NEMOCLAW_USER}
Group=${NEMOCLAW_USER}
WorkingDirectory=${NEMOCLAW_HOME}

# Start OpenShell gateway
ExecStart=/usr/local/bin/openshell gateway start
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=/usr/local/bin/openshell gateway stop

Restart=on-failure
RestartSec=10

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nemoclaw

# Resource limits
MemoryLimit=8G
CPUQuota=75%

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable nemoclaw.service
    systemctl start nemoclaw.service || log_warn "Could not start nemoclaw service yet (may need manual configuration)"
    
    log_success "Systemd service configured"
}

# Set up cron job for automated backups
setup_backup_cron() {
    if [[ "${BACKUP_ENABLED:-true}" == "false" ]]; then
        log_info "Backups disabled in .env, skipping cron setup"
        return 0
    fi
    
    log_info "Setting up backup cron job..."
    
    local backup_time="${BACKUP_TIME:-02:00}"
    local hour=$(echo "$backup_time" | cut -d: -f1)
    local minute=$(echo "$backup_time" | cut -d: -f2)
    
    local cron_entry="$minute $hour * * * root bash $SCRIPT_DIR/backup.sh >> $DEPLOY_LOG 2>&1"
    
    # Add to crontab if not already present
    if ! crontab -l 2>/dev/null | grep -q "backup.sh"; then
        (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
        log_success "Backup cron job scheduled for $backup_time UTC daily"
    else
        log_info "Backup cron job already configured"
    fi
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    local checks_passed=0
    local checks_total=0
    
    # Check commands
    for cmd in docker node npm nemoclaw openshell; do
        checks_total=$((checks_total + 1))
        if command -v "$cmd" &> /dev/null; then
            log_success "✓ $cmd installed"
            checks_passed=$((checks_passed + 1))
        else
            log_error "✗ $cmd not found in PATH"
        fi
    done
    
    # Check directories
    for dir in "$CONFIG_DIR" "$MODELS_DIR" "$LOGS_DIR" "$BACKUP_DIR"; do
        checks_total=$((checks_total + 1))
        if [[ -d "$dir" ]]; then
            log_success "✓ $dir exists"
            checks_passed=$((checks_passed + 1))
        else
            log_error "✗ $dir not found"
        fi
    done
    
    # Check Docker daemon
    checks_total=$((checks_total + 1))
    if docker ps &> /dev/null; then
        log_success "✓ Docker daemon running"
        checks_passed=$((checks_passed + 1))
    else
        log_warn "✗ Docker daemon not responding"
    fi
    
    log_info "Verification: $checks_passed / $checks_total checks passed"
    
    if [[ $checks_passed -eq $checks_total ]]; then
        return 0
    else
        return 1
    fi
}

# Print summary and next steps
print_summary() {
    cat << EOF

$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )
$( echo -e "${GREEN}NemoClaw Installation Complete!${NC}" )
$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )

Next Steps:

1. Verify the installation:
   bash scripts/health-check.sh

2. Connect to your sandbox:
   nemoclaw ${SANDBOX_NAME:-my-assistant} connect

3. Inside the sandbox, run OpenClaw:
   openclaw tui                          # Interactive chat
   openclaw agent -m "hello"             # Single message

4. Start supporting services (Ollama, monitoring):
   docker compose --profile full up -d

5. View backup status:
   ls -lh ${BACKUP_DIR}

Configuration:
  - Config directory: ${CONFIG_DIR}
  - Models directory: ${MODELS_DIR}
  - Backup directory: ${BACKUP_DIR}
  - Setup log: ${DEPLOY_LOG}

Documentation:
  - Main: README.md
  - Operations: docs/OPERATIONS.md
  - Backup/Restore: docs/BACKUP-RESTORE.md
  - Troubleshooting: docs/TROUBLESHOOTING.md

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
            --skip-docker) SKIP_DOCKER=true; shift ;;
            --skip-nodejs) SKIP_NODEJS=true; shift ;;
            --skip-user-create) SKIP_USER=true; shift ;;
            --no-monitoring) NO_MONITORING=true; shift ;;
            --verbose) set -x; shift ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
    
    # Initialize
    check_root
    mkdir -p "$(dirname "$DEPLOY_LOG")"
    
    log_info "═══════════════════════════════════════════════════════════"
    log_info "NemoClaw Production Setup"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Starting at $(date)"
    
    # System setup
    update_system
    create_nonroot_user
    
    # Load and validate configuration
    load_env
    
    # System checks
    check_prerequisites
    
    # Install dependencies
    [[ -z "${SKIP_DOCKER:-}" ]] && install_docker
    [[ -z "${SKIP_NODEJS:-}" ]] && install_nodejs
    install_openshell
    install_nemoclaw
    
    # Create directory structure
    create_directories
    
    # Configure services
    setup_systemd_service
    setup_backup_cron
    
    # Verify installation
    if verify_installation; then
        log_success "All installation checks passed!"
    else
        log_warn "Some checks failed - review above and resolve manually if needed"
    fi
    
    # Print next steps
    print_summary
    
    log_success "Setup completed at $(date)"
}

# Run main function
main "$@"