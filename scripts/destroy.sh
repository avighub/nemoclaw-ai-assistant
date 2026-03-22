#!/bin/bash

##############################################################################
# NemoClaw Complete Destroy Script (Vendor-Agnostic)
#
# Completely removes EVERYTHING created by setup.sh, leaving server clean.
# This design is vendor-agnostic - works on any VPS provider.
#
# IMPORTANT: User is responsible for backing up before running this!
#   bash scripts/backup.sh     # Create backup BEFORE destroy
#
# Removes:
#   - NemoClaw services (systemd, Docker, OpenShell)
#   - Docker installation (apt-get purge)
#   - Node.js installation (apt-get purge)
#   - OpenShell (pip3 uninstall)
#   - /srv/nemoclaw/ (config, models, backups, logs - EVERYTHING)
#   - Cron jobs
#   - systemd service files
#
# Result: Clean server, just as it was before setup.sh
#
# Usage: bash scripts/destroy.sh [--help]
##############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
Usage: bash scripts/destroy.sh [OPTIONS]

Completely removes everything created by setup.sh.
Server will be clean and ready for other uses.

⚠️  WARNING: This removes EVERYTHING including /srv/nemoclaw/

Options:
  --help              Show this help message
  --yes               Skip confirmation prompt
  --verbose           Enable verbose output
  --keep-docker       Don't uninstall Docker (keep common packages)
  --keep-nodejs       Don't uninstall Node.js (keep common packages)
  --keep-docker-nodejs Keep both Docker and Node.js

BEFORE destroying, ensure you have a backup:
  bash scripts/backup.sh

Then destroy:
  bash scripts/destroy.sh --yes

Examples:
  bash scripts/destroy.sh
  bash scripts/destroy.sh --yes --verbose
  bash scripts/destroy.sh --yes --keep-docker-nodejs
  bash scripts/destroy.sh --yes --keep-docker --keep-nodejs
EOF
    exit 0
}

# Print what will be destroyed
print_destruction_plan() {
    # Determine mode label
    local mode_label
    if [[ "${KEEP_DOCKER:-false}" == "true" && "${KEEP_NODEJS:-false}" == "true" ]]; then
        mode_label="PARTIAL DESTRUCTION — Keeping Docker + Node.js"
    elif [[ "${KEEP_DOCKER:-false}" == "true" ]]; then
        mode_label="PARTIAL DESTRUCTION — Keeping Docker"
    elif [[ "${KEEP_NODEJS:-false}" == "true" ]]; then
        mode_label="PARTIAL DESTRUCTION — Keeping Node.js"
    else
        mode_label="FULL DESTRUCTION"
    fi

    echo ""
    echo -e "${RED}═══ ${mode_label} ═══${NC}"
    echo ""
    echo "Removing:"
    echo -e "  ${RED}✗${NC} NemoClaw services         — systemd unit, OpenShell gateway"
    echo -e "  ${RED}✗${NC} Docker containers/images  — all containers, images, networks, volumes"

    if [[ "${KEEP_DOCKER:-false}" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} Docker installation       — KEEPING (binary/daemon preserved)"
    else
        echo -e "  ${RED}✗${NC} Docker installation       — will be purged (apt-get purge)"
    fi

    if [[ "${KEEP_NODEJS:-false}" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} Node.js installation      — KEEPING (binary preserved)"
    else
        echo -e "  ${RED}✗${NC} Node.js installation      — will be purged (apt-get purge)"
    fi

    echo -e "  ${RED}✗${NC} OpenShell                 — pip3 package + binary"
    echo -e "  ${RED}✗${NC} /srv/nemoclaw/            — config, models, backups, logs"
    echo -e "  ${RED}✗${NC} Cron jobs                 — backup runner"
    echo -e "  ${RED}✗${NC} nemoclaw user             — system user + home directory"
    echo ""
    echo "Server state after:"
    echo "  → NemoClaw fully removed"
    if [[ "${KEEP_DOCKER:-false}" == "true" || "${KEEP_NODEJS:-false}" == "true" ]]; then
        echo "  → Selected packages preserved (see above)"
    fi
    echo "  → Ready for fresh setup.sh or other uses"
    echo ""
    echo -e "${YELLOW}⚠️  Make sure you have backed up!${NC}"
    echo "  bash scripts/backup.sh  # Run THIS before destroying"
    echo ""
}

# Confirmation prompt
confirm_destruction() {
    if [[ "${YES:-false}" == "true" ]]; then
        log_warn "Proceeding without confirmation (--yes flag)"
        return 0
    fi

    print_destruction_plan

    local prompt_label="complete removal"
    if [[ "${KEEP_DOCKER:-false}" == "true" && "${KEEP_NODEJS:-false}" == "true" ]]; then
        prompt_label="partial removal (keeping Docker + Node.js)"
    elif [[ "${KEEP_DOCKER:-false}" == "true" ]]; then
        prompt_label="partial removal (keeping Docker)"
    elif [[ "${KEEP_NODEJS:-false}" == "true" ]]; then
        prompt_label="partial removal (keeping Node.js)"
    fi

    read -p "Type 'destroy' to confirm ${prompt_label}: " -r response

    if [[ "$response" != "destroy" ]]; then
        log_warn "Destruction cancelled"
        exit 0
    fi
}

# Stop services
stop_services() {
    log_info "Stopping services..."
    
    # Stop docker compose
    if docker compose ps &> /dev/null 2>&1; then
        log_info "  Stopping Docker Compose..."
        docker compose down 2>/dev/null || true
    fi
    
    # Stop nemoclaw systemd service
    if systemctl is-active nemoclaw.service &> /dev/null; then
        log_info "  Stopping nemoclaw service..."
        systemctl stop nemoclaw.service 2>/dev/null || true
    fi
    
    # Disable services
    systemctl disable nemoclaw.service 2>/dev/null || true
    
    # Kill any remaining processes
    pkill -f "openshell" 2>/dev/null || true
    pkill -f "nemoclaw" 2>/dev/null || true
    
    sleep 2
    log_success "Services stopped"
}

# Remove Docker resources
remove_docker_resources() {
    log_info "Removing Docker resources..."
    
    if ! command -v docker &> /dev/null; then
        log_info "  Docker not found, skipping"
        return 0
    fi
    
    # Remove containers
    log_info "  Removing containers..."
    docker container prune -af 2>/dev/null || true
    
    # Remove images
    log_info "  Removing images..."
    docker image prune -af 2>/dev/null || true
    
    # Remove networks
    log_info "  Removing networks..."
    docker network prune -f 2>/dev/null || true
    
    # Remove volumes
    log_info "  Removing volumes..."
    docker volume prune -af 2>/dev/null || true
    
    log_success "Docker resources removed"
}

# Remove persistent data directory
remove_data_directory() {
    log_info "Removing /srv/nemoclaw/..."
    
    if [[ -d /srv/nemoclaw ]]; then
        rm -rf /srv/nemoclaw
        log_success "Removed /srv/nemoclaw/"
    else
        log_info "  /srv/nemoclaw/ not found (already removed)"
    fi
}

# Remove systemd service files
remove_systemd_services() {
    log_info "Removing systemd service files..."
    
    if [[ -f /etc/systemd/system/nemoclaw.service ]]; then
        rm /etc/systemd/system/nemoclaw.service
        log_info "  Removed /etc/systemd/system/nemoclaw.service"
    fi
    
    systemctl daemon-reload 2>/dev/null || true
    
    log_success "Systemd services removed"
}

# Remove cron jobs
remove_cron_jobs() {
    log_info "Removing cron jobs..."
    
    # Remove nemoclaw backup cron job
    (crontab -l 2>/dev/null | grep -v "backup.sh" | crontab - 2>/dev/null) || true
    
    log_success "Cron jobs removed"
}

# Uninstall Docker
uninstall_docker() {
    if [[ "${KEEP_DOCKER:-false}" == "true" ]]; then
        log_info "Skipping Docker uninstall (--keep-docker flag)"
        return 0
    fi
    
    log_info "Uninstalling Docker..."
    
    if ! command -v docker &> /dev/null; then
        log_info "  Docker not found (already removed)"
        return 0
    fi
    
    apt-get remove -y docker.io docker-ce docker-ce-cli 2>/dev/null || true
    apt-get purge -y docker.io docker-ce docker-ce-cli 2>/dev/null || true
    
    # Remove Docker group
    groupdel docker 2>/dev/null || true
    
    log_success "Docker uninstalled"
}

# Uninstall Node.js
uninstall_nodejs() {
    if [[ "${KEEP_NODEJS:-false}" == "true" ]]; then
        log_info "Skipping Node.js uninstall (--keep-nodejs flag)"
        return 0
    fi
    
    log_info "Uninstalling Node.js..."
    
    if ! command -v node &> /dev/null; then
        log_info "  Node.js not found (already removed)"
        return 0
    fi
    
    apt-get remove -y nodejs npm 2>/dev/null || true
    apt-get purge -y nodejs npm 2>/dev/null || true
    
    # Remove NodeSource repository if added
    rm /etc/apt/sources.list.d/nodesource.list 2>/dev/null || true
    apt-get update 2>/dev/null || true
    
    log_success "Node.js uninstalled"
}

# Uninstall OpenShell
uninstall_openshell() {
    log_info "Uninstalling OpenShell..."
    
    if ! command -v openshell &> /dev/null; then
        log_info "  OpenShell not found (already removed)"
        return 0
    fi
    
    # Remove binary
    rm /usr/local/bin/openshell 2>/dev/null || true
    
    # Uninstall pip package
    if command -v pip3 &> /dev/null; then
        pip3 uninstall -y openshell 2>/dev/null || true
    fi
    
    log_success "OpenShell uninstalled"
}

# Remove nemoclaw user
remove_nemoclaw_user() {
    log_info "Removing nemoclaw user..."
    
    if ! id nemoclaw &>/dev/null; then
        log_info "  User nemoclaw not found (already removed)"
        return 0
    fi
    
    # Kill any processes running as nemoclaw
    pkill -u nemoclaw 2>/dev/null || true
    
    # Remove user and home directory
    userdel -r nemoclaw 2>/dev/null || true
    
    log_success "User nemoclaw removed"
}

# Verify destruction
verify_destruction() {
    log_info "Verifying destruction..."
    
    local issues=0
    
    # Check services removed
    if systemctl is-enabled nemoclaw.service 2>/dev/null; then
        log_warn "⚠ nemoclaw service still enabled"
        issues=$((issues + 1))
    else
        log_success "✓ nemoclaw service removed"
    fi
    
    # Check Docker removed (unless --keep-docker)
    if [[ "${KEEP_DOCKER:-false}" != "true" ]]; then
        if command -v docker &> /dev/null; then
            log_warn "⚠ docker still installed"
            issues=$((issues + 1))
        else
            log_success "✓ docker removed"
        fi
    else
        log_success "✓ docker kept (--keep-docker flag)"
    fi
    
    # Check Node.js removed (unless --keep-nodejs)
    if [[ "${KEEP_NODEJS:-false}" != "true" ]]; then
        if command -v node &> /dev/null; then
            log_warn "⚠ node still installed"
            issues=$((issues + 1))
        else
            log_success "✓ node removed"
        fi
    else
        log_success "✓ node kept (--keep-nodejs flag)"
    fi
    
    # Check /srv/nemoclaw removed
    if [[ -d /srv/nemoclaw ]]; then
        log_warn "⚠ /srv/nemoclaw/ still exists"
        issues=$((issues + 1))
    else
        log_success "✓ /srv/nemoclaw/ removed"
    fi
    
    if [[ $issues -eq 0 ]]; then
        log_success "Destruction verified!"
        return 0
    else
        log_warn "Destruction completed with $issues issue(s)"
        return 1
    fi
}

# Print summary
print_summary() {
    local kept_packages=""
    if [[ "${KEEP_DOCKER:-false}" == "true" ]]; then
        kept_packages="Docker "
    fi
    if [[ "${KEEP_NODEJS:-false}" == "true" ]]; then
        kept_packages+="Node.js"
    fi
    
    cat << EOF

$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )
$( echo -e "${GREEN}NemoClaw Complete Destruction Complete!${NC}" )
$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )

Removed:
  ✓ NemoClaw services and containers
  $( [[ "${KEEP_DOCKER:-false}" != "true" ]] && echo "✓ Docker installation" || echo "✗ Docker (KEPT)" )
  $( [[ "${KEEP_NODEJS:-false}" != "true" ]] && echo "✓ Node.js installation" || echo "✗ Node.js (KEPT)" )
  ✓ OpenShell installation
  ✓ /srv/nemoclaw/ (all data)
  ✓ Systemd service files
  ✓ Cron jobs
  ✓ nemoclaw user

Result: Server is clean and ready for:
  • Fresh setup.sh installation
  • Other projects
  • VPS decommissioning

Reinstall NemoClaw:
  bash scripts/setup.sh

Restore from backup:
  1. Copy your backup files to the server
  2. Run: bash scripts/restore.sh <backup-file>
  3. Run: bash scripts/setup.sh

$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )
EOF
}

##############################################################################
# Main Destruction Flow
##############################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help) usage ;;
            --yes) YES=true; shift ;;
            --verbose) set -x; shift ;;
            --keep-docker) KEEP_DOCKER=true; shift ;;
            --keep-nodejs) KEEP_NODEJS=true; shift ;;
            --keep-docker-nodejs) KEEP_DOCKER=true; KEEP_NODEJS=true; shift ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
    
    log_info "═══════════════════════════════════════════════════════════"
    log_info "NemoClaw Complete Destruction"
    log_info "═══════════════════════════════════════════════════════════"
    
    # Confirm
    confirm_destruction
    
    # Execute destruction
    stop_services
    remove_docker_resources
    remove_data_directory
    remove_systemd_services
    remove_cron_jobs
    uninstall_docker
    uninstall_nodejs
    uninstall_openshell
    remove_nemoclaw_user
    
    # Verify
    verify_destruction
    
    # Summary
    print_summary
    
    log_success "Destruction completed at $(date)"
}

# Run main
main "$@"