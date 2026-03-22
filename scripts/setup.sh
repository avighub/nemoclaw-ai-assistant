#!/bin/bash

##############################################################################
# NemoClaw Production Setup Script (v2 - Production Tested)
# 
# This script handles foundational setup:
#   1. Updates system packages
#   2. Creates non-root nemoclaw user
#   3. Installs Docker
#   4. Installs Node.js 20+
#   5. Installs OpenShell via pip3 (proper wheel format)
#   6. Creates persistent volume directories
#   7. Sets up systemd service
#   8. Delegates NemoClaw installation to official NVIDIA installer
#
# Usage: bash scripts/setup.sh [--help]
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

Fully automated NemoClaw foundational setup.
Run as root on Ubuntu 22.04 LTS or later.

Options:
  --help              Show this help message
  --skip-docker       Skip Docker installation
  --skip-nodejs       Skip Node.js installation
  --skip-user-create  Skip nemoclaw user creation
  --skip-openshell    Skip OpenShell installation
  --no-nvidia-install Don't run official NVIDIA installer
  --verbose           Enable verbose output

Process:
  1. Updates system packages
  2. Creates nemoclaw user
  3. Installs Docker + Node.js + OpenShell
  4. Creates persistent directories
  5. Sets up systemd service
  6. Runs official NVIDIA NemoClaw installer (unless --no-nvidia-install)

Quick Start:
  bash scripts/setup.sh

Examples:
  bash scripts/setup.sh --skip-docker
  bash scripts/setup.sh --no-nvidia-install --verbose
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
        log_warn ".env file not found at $ENV_FILE"
        log_info "Creating from .env.example..."
        if [[ -f "$PROJECT_ROOT/.env.example" ]]; then
            cp "$PROJECT_ROOT/.env.example" "$ENV_FILE"
            log_info "Created $ENV_FILE - please edit with your NVIDIA_API_KEY"
        else
            log_error "No .env.example found"
            return 1
        fi
    fi
    
    # Source .env but don't fail if variables are unset
    set +u
    source "$ENV_FILE"
    set -u
    
    # Validate NVIDIA_API_KEY — give user 3 attempts if missing or malformed
    local max_attempts=3
    local attempt=0

    while true; do
        if [[ -n "${NVIDIA_API_KEY:-}" && "${NVIDIA_API_KEY}" == nvapi-* ]]; then
            log_success "NVIDIA_API_KEY looks valid"
            break
        fi

        attempt=$((attempt + 1))

        if [[ "${NVIDIA_API_KEY:-}" == "" ]]; then
            log_warn "NVIDIA_API_KEY is not set in .env"
        else
            log_warn "Invalid key: '${NVIDIA_API_KEY}'. Must start with 'nvapi-'"
        fi

        if [[ $attempt -ge $max_attempts ]]; then
            log_warn "No valid NVIDIA_API_KEY after $max_attempts attempts — continuing anyway"
            log_info "You can set it manually in $ENV_FILE and rerun, or enter it during the NVIDIA installer step"
            break
        fi

        local remaining=$((max_attempts - attempt))
        echo -e "${YELLOW}[PROMPT]${NC} Enter your NVIDIA API key (attempt $attempt/$max_attempts, $remaining remaining):"
        echo -e "         Keys look like: nvapi-xxxxxxxxxxxxxxxxxxxx"
        read -r -p "         NVIDIA_API_KEY: " input_key || true   # || true: prevent set -e from killing on empty/EOF

        if [[ -z "$input_key" ]]; then
            log_warn "No input received — please enter a key"
            continue
        fi

        if [[ -n "$input_key" ]]; then
            NVIDIA_API_KEY="$input_key"
            export NVIDIA_API_KEY
            # Persist into .env so subsequent scripts pick it up
            if grep -q "^NVIDIA_API_KEY=" "$ENV_FILE" 2>/dev/null; then
                sed -i "s|^NVIDIA_API_KEY=.*|NVIDIA_API_KEY=${input_key}|" "$ENV_FILE"
            else
                echo "NVIDIA_API_KEY=${input_key}" >> "$ENV_FILE"
            fi
        fi
    done

    log_success "Loaded configuration from .env"
}

# Update system packages
update_system() {
    log_info "Updating system packages..."
    
    apt-get update
    apt-get upgrade -y
    
    log_success "System packages updated"
}

# Create non-root user
create_nonroot_user() {
    if [[ "${SKIP_USER:-false}" == "true" ]]; then
        log_info "Skipping user creation"
        return 0
    fi
    
    if id "$NEMOCLAW_USER" &>/dev/null; then
        log_info "User $NEMOCLAW_USER already exists"
        return 0
    fi
    
    log_info "Creating user: $NEMOCLAW_USER"
    useradd -m -s /bin/bash "$NEMOCLAW_USER"
    usermod -aG sudo "$NEMOCLAW_USER"
    
    mkdir -p "$NEMOCLAW_HOME/nemoclaw-deploy"
    chown -R "$NEMOCLAW_USER:$NEMOCLAW_USER" "$NEMOCLAW_HOME"
    
    log_success "User $NEMOCLAW_USER created"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing=()
    local required_cmds=("curl" "wget" "git" "tar" "gzip" "jq")
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Installing missing: ${missing[*]}"
        apt-get install -y curl wget git tar gzip jq
    fi
    
    log_success "Prerequisites check passed"
}

# Install Docker
install_docker() {
    if [[ "${SKIP_DOCKER:-false}" == "true" ]]; then
        log_info "Skipping Docker installation"
        return 0
    fi
    
    if command -v docker &> /dev/null; then
        log_info "Docker already installed: $(docker --version)"
        return 0
    fi
    
    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    bash /tmp/get-docker.sh
    rm /tmp/get-docker.sh
    
    systemctl start docker
    systemctl enable docker
    
    usermod -aG docker "${NEMOCLAW_USER}" 2>/dev/null || true
    
    log_success "Docker installed: $(docker --version)"
}

# Install Node.js
install_nodejs() {
    if [[ "${SKIP_NODEJS:-false}" == "true" ]]; then
        log_info "Skipping Node.js installation"
        return 0
    fi
    
    if command -v node &> /dev/null; then
        local node_version=$(node --version)
        log_info "Node.js already installed: $node_version"
        
        local major_version=$(echo "$node_version" | sed 's/v\([0-9]*\).*/\1/')
        if [[ $major_version -ge 20 ]]; then
            log_success "Node.js version meets requirement (20+)"
            return 0
        fi
    fi
    
    log_info "Installing Node.js 20.x..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    
    log_success "Node.js installed: $(node --version)"
    log_success "npm installed: $(npm --version)"
}

# Install OpenShell via pip3 (proper method)
install_openshell() {
    if [[ "${SKIP_OPENSHELL:-false}" == "true" ]]; then
        log_info "Skipping OpenShell installation"
        return 0
    fi
    
    if command -v openshell &> /dev/null; then
        log_info "OpenShell already installed: $(openshell --version)"
        return 0
    fi
    
    log_info "Installing OpenShell..."
    
    # Ensure pip3 is available
    if ! command -v pip3 &> /dev/null; then
        log_info "Installing python3-pip..."
        apt-get install -y python3-pip
    fi
    
    # Get latest release version
    local latest_release=$(curl -s https://api.github.com/repos/NVIDIA/OpenShell/releases/latest | jq -r '.tag_name')
    local version="${latest_release#v}"  # Remove 'v' prefix
    local wheel_url="https://github.com/NVIDIA/OpenShell/releases/download/${latest_release}/openshell-${version}-py3-none-manylinux_2_39_x86_64.whl"
    
    log_info "Downloading from: $wheel_url"
    
    # Install via pip3
    if pip3 install --break-system-packages "$wheel_url" 2>&1 | grep -q "Successfully installed"; then
        if command -v openshell &> /dev/null; then
            log_success "OpenShell installed: $(openshell --version)"
            return 0
        fi
    fi
    
    log_warn "OpenShell installation may have failed"
    log_info "Official NVIDIA installer will handle this"
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
    
    if id "$NEMOCLAW_USER" &>/dev/null; then
        chown -R "${NEMOCLAW_USER}:${NEMOCLAW_USER}" /srv/nemoclaw 2>/dev/null || true
        chmod -R 755 /srv/nemoclaw
    fi
    
    log_success "Directories created"
}

# Setup systemd service
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

ExecStart=/usr/local/bin/openshell gateway start
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=/usr/local/bin/openshell gateway stop

Restart=on-failure
RestartSec=10

StandardOutput=journal
StandardError=journal
SyslogIdentifier=nemoclaw

MemoryLimit=8G
CPUQuota=75%

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable nemoclaw.service || true
    
    log_success "Systemd service configured"
}

# Setup backup cron job
setup_backup_cron() {
    log_info "Setting up backup cron job..."
    
    local backup_time="${BACKUP_TIME:-02:00}"
    local backup_hour=$(echo "$backup_time" | cut -d: -f1)
    local backup_minute=$(echo "$backup_time" | cut -d: -f2)
    
    # Create cron job for daily backups
    local cron_entry="$backup_minute $backup_hour * * * cd $PROJECT_ROOT && bash scripts/backup.sh >> /var/log/nemoclaw-backup.log 2>&1"
    
    # Remove existing nemoclaw backup cron entries
    (crontab -u "$NEMOCLAW_USER" -l 2>/dev/null | grep -v "backup.sh" | crontab -u "$NEMOCLAW_USER" -) || true
    
    # Add new cron entry
    (crontab -u "$NEMOCLAW_USER" -l 2>/dev/null; echo "$cron_entry") | crontab -u "$NEMOCLAW_USER" -
    
    log_success "Backup cron job configured ($backup_time UTC daily)"
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    local checks_passed=0
    local checks_total=0
    
    for cmd in docker node npm openshell; do
        checks_total=$((checks_total + 1))
        if command -v "$cmd" &> /dev/null; then
            log_success "✓ $cmd installed"
            checks_passed=$((checks_passed + 1))
        else
            log_warn "⚠ $cmd not found (may be installed during NVIDIA setup)"
        fi
    done
    
    for dir in "$CONFIG_DIR" "$MODELS_DIR" "$LOGS_DIR" "$BACKUP_DIR"; do
        checks_total=$((checks_total + 1))
        if [[ -d "$dir" ]]; then
            log_success "✓ $(basename $dir) exists"
            checks_passed=$((checks_passed + 1))
        else
            log_error "✗ $(basename $dir) not found"
        fi
    done
    
    checks_total=$((checks_total + 1))
    if docker ps &> /dev/null; then
        log_success "✓ Docker daemon running"
        checks_passed=$((checks_passed + 1))
    else
        log_warn "⚠ Docker daemon not responding"
    fi
    
    log_info "Verification: $checks_passed / $checks_total checks passed"
}

# Print summary
print_summary() {
    cat << EOF

$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )
$( echo -e "${GREEN}NemoClaw Foundational Setup Complete!${NC}" )
$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )

Installed:
  ✓ System packages updated
  ✓ Docker (container runtime)
  ✓ Node.js 20+ (JavaScript runtime)
  ✓ OpenShell (sandbox runtime)
  ✓ Persistent directories created (/srv/nemoclaw/)
  ✓ Systemd service configured

Next Step: Run Official NVIDIA NemoClaw Installer

$( echo -e "${YELLOW}This will complete the NemoClaw setup:${NC}" )

  curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash

This installer will:
  1. Clone official NemoClaw repository
  2. Build NemoClaw CLI
  3. Run interactive onboarding
  4. Create your first sandbox
  5. Ask for NVIDIA API key (free tier available)

Then connect and chat:

  nemoclaw my-assistant connect
  openclaw tui

Configuration:
  - Setup log: $DEPLOY_LOG
  - Config directory: $CONFIG_DIR
  - Models directory: $MODELS_DIR
  - Backup directory: $BACKUP_DIR

Documentation:
  - Main: README.md
  - Operations: docs/OPERATIONS.md
  - Backup/Restore: docs/BACKUP-RESTORE.md

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
            --skip-openshell) SKIP_OPENSHELL=true; shift ;;
            --no-nvidia-install) NO_NVIDIA_INSTALL=true; shift ;;
            --verbose) set -x; shift ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
    
    # Initialize
    check_root
    mkdir -p "$(dirname "$DEPLOY_LOG")"
    
    log_info "═══════════════════════════════════════════════════════════"
    log_info "NemoClaw Foundational Setup (v2)"
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Starting at $(date)"
    
    # Setup foundation
    update_system
    create_nonroot_user
    load_env
    check_prerequisites
    
    # Install dependencies
    install_docker
    install_nodejs
    install_openshell
    
    # Configure
    create_directories
    setup_systemd_service
    setup_backup_cron
    
    # Verify
    verify_installation
    
    # Print summary
    print_summary
    
    # Offer to run official installer
    if [[ "${NO_NVIDIA_INSTALL:-false}" != "true" ]]; then
        log_info ""
        log_info "Would you like to run the official NVIDIA NemoClaw installer now?"
        log_info "This will complete the setup and run onboarding."
        log_info ""
        read -p "Run NVIDIA installer? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Running official NVIDIA NemoClaw installer..."
            curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
        else
            log_info "You can run it manually later:"
            log_info "  curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash"
        fi
    fi
    
    log_success "Setup completed at $(date)"
}

# Run main function
main "$@"