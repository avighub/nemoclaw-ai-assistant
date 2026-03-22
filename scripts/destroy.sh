#!/bin/bash

##############################################################################
# NemoClaw Destroy Script
#
# Cleanly removes all NemoClaw services and Docker containers
# PRESERVES all data in /srv/nemoclaw (config, models, backups, logs)
#
# Steps:
#   1. Stops all services
#   2. Removes Docker containers and networks
#   3. Removes Docker volumes (but saves their data first)
#   4. Removes systemd services
#   5. KEEPS /srv/nemoclaw/ intact (allows reinstall)
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

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/srv/nemoclaw/backups}"

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

Removes all NemoClaw services and Docker resources.
Data in /srv/nemoclaw is PRESERVED for easy recovery.

Options:
  --help              Show this help message
  --yes               Skip confirmation prompt
  --keep-backups      Don't backup current state before destroying
  --verbose           Enable verbose output
  --also-delete-data  Delete /srv/nemoclaw/ too (DANGEROUS!)

Examples:
  bash scripts/destroy.sh
  bash scripts/destroy.sh --yes
  bash scripts/destroy.sh --also-delete-data --yes
EOF
    exit 0
}

# Print what will be destroyed
print_destruction_plan() {
    cat << EOF

$( echo -e "${YELLOW}Destruction Plan:${NC}" )

Services to stop:
  ✓ Docker Compose services (Ollama, Prometheus, Grafana, backup runner)
  ✓ nemoclaw systemd service
  ✓ OpenShell gateway

Docker resources to remove:
  ✓ All containers (nemoclaw-*, backup-runner, etc.)
  ✓ Docker networks (nemoclaw)
  ✓ Docker volumes

Data PRESERVED (for recovery):
  ✓ /srv/nemoclaw/config    (NemoClaw configuration)
  ✓ /srv/nemoclaw/models    (Ollama model cache)
  ✓ /srv/nemoclaw/backups   (Backup files)
  ✓ /srv/nemoclaw/logs      (Service logs)

After destruction:
  - Can reinstall cleanly with: bash scripts/setup.sh
  - Can restore from backup with: bash scripts/restore.sh <backup>

EOF
}

# Confirmation prompt
confirm_destruction() {
    echo -e "${RED}WARNING: This will remove all NemoClaw services!${NC}"
    print_destruction_plan
    
    if [[ "${YES:-false}" == "true" ]]; then
        log_warn "Proceeding without confirmation (--yes flag)"
        return 0
    fi
    
    read -p "Do you want to proceed with destruction? (type 'destroy' to confirm): " -r response
    
    if [[ "$response" != "destroy" ]]; then
        log_warn "Destruction cancelled"
        exit 0
    fi
}

# Backup current state before destruction
backup_before_destroy() {
    if [[ "${KEEP_BACKUPS:-false}" == "true" ]]; then
        log_info "Skipping pre-destruction backup"
        return 0
    fi
    
    log_info "Creating final backup before destruction..."
    
    local final_backup="$BACKUP_DIR/pre-destroy-backup-$(date -u +'%Y-%m-%d-%H-%M-%S').tar.gz"
    
    mkdir -p "$BACKUP_DIR"
    
    tar -czf "$final_backup" \
        --exclude='*.log' \
        --exclude='__pycache__' \
        --transform='s|^/srv/nemoclaw|nemoclaw-data|' \
        /srv/nemoclaw 2>/dev/null || {
        log_warn "Could not create pre-destruction backup"
        return 1
    }
    
    local size=$(du -h "$final_backup" | cut -f1)
    log_success "Final backup created: $final_backup ($size)"
}

# Stop all services
stop_services() {
    log_info "Stopping services..."
    
    # Stop docker compose
    if docker compose ps &> /dev/null; then
        log_info "  Stopping Docker Compose services..."
        docker compose down 2>/dev/null || true
    fi
    
    # Stop nemoclaw systemd service
    if systemctl is-enabled nemoclaw.service &> /dev/null; then
        log_info "  Stopping nemoclaw systemd service..."
        systemctl stop nemoclaw.service 2>/dev/null || true
        systemctl disable nemoclaw.service 2>/dev/null || true
    fi
    
    # Kill any remaining openshell processes
    pkill -f "openshell" 2>/dev/null || true
    
    sleep 2
    log_success "Services stopped"
}

# Remove Docker containers and networks
remove_docker_resources() {
    log_info "Removing Docker resources..."
    
    # Remove containers
    local containers=$(docker ps -a --filter "label=com.nemoclaw.service" -q 2>/dev/null || echo "")
    if [[ -n "$containers" ]]; then
        log_info "  Removing nemoclaw containers..."
        docker rm -f $containers 2>/dev/null || true
    fi
    
    # Remove other nemoclaw-* containers
    local other_containers=$(docker ps -a --filter "name=nemoclaw-" -q 2>/dev/null || echo "")
    if [[ -n "$other_containers" ]]; then
        docker rm -f $other_containers 2>/dev/null || true
    fi
    
    # Remove networks
    local networks=$(docker network ls --filter "name=nemoclaw" -q 2>/dev/null || echo "")
    if [[ -n "$networks" ]]; then
        log_info "  Removing nemoclaw networks..."
        docker network rm $networks 2>/dev/null || true
    fi
    
    # Prune unused volumes (but our bind mounts will remain)
    log_info "  Pruning unused Docker volumes..."
    docker volume prune -f --filter "label=com.nemoclaw.service" 2>/dev/null || true
    
    log_success "Docker resources removed"
}

# Remove systemd service files
remove_systemd_services() {
    log_info "Removing systemd service files..."
    
    if [[ -f /etc/systemd/system/nemoclaw.service ]]; then
        rm /etc/systemd/system/nemoclaw.service
        log_info "  Removed: /etc/systemd/system/nemoclaw.service"
    fi
    
    # Reload systemd
    systemctl daemon-reload 2>/dev/null || true
    
    log_success "Systemd services removed"
}

# Remove cron jobs
remove_cron_jobs() {
    log_info "Removing cron jobs..."
    
    # Remove backup cron job
    crontab -l 2>/dev/null | grep -v "backup.sh" | crontab - 2>/dev/null || true
    
    log_success "Cron jobs removed"
}

# Remove installed packages (optional, depending on flag)
remove_packages() {
    log_warn "Skipping package removal (Docker, Node.js, OpenShell remain)"
    log_info "To uninstall these, run: apt-get purge docker.io nodejs npm"
    log_info "Or use: npm uninstall -g nemoclaw openshell"
}

# Verify destruction completed
verify_destruction() {
    log_info "Verifying destruction..."
    
    local issues=0
    
    # Check no nemoclaw containers running
    if docker ps --filter "name=nemoclaw-" --filter "status=running" | grep -q nemoclaw; then
        log_warn "⚠ Some nemoclaw containers still running"
        issues=$((issues + 1))
    else
        log_success "✓ No nemoclaw containers running"
    fi
    
    # Check no nemoclaw network
    if docker network ls --filter "name=nemoclaw" | grep -q nemoclaw; then
        log_warn "⚠ nemoclaw network still exists"
        issues=$((issues + 1))
    else
        log_success "✓ nemoclaw network removed"
    fi
    
    # Check no systemd service
    if systemctl is-enabled nemoclaw.service 2>/dev/null; then
        log_warn "⚠ nemoclaw systemd service still enabled"
        issues=$((issues + 1))
    else
        log_success "✓ nemoclaw systemd service removed"
    fi
    
    # Check data still exists
    if [[ -d /srv/nemoclaw ]]; then
        local size=$(du -sh /srv/nemoclaw | cut -f1)
        log_success "✓ /srv/nemoclaw preserved ($size)"
    else
        log_error "✗ /srv/nemoclaw was removed!"
        issues=$((issues + 1))
    fi
    
    if [[ $issues -eq 0 ]]; then
        log_success "Destruction verified - all services removed"
        return 0
    else
        log_warn "Destruction completed with $issues issue(s)"
        return 1
    fi
}

# Print destruction summary
print_summary() {
    cat << EOF

$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )
$( echo -e "${GREEN}NemoClaw Destruction Complete!${NC}" )
$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )

Removed:
  ✓ Docker containers
  ✓ Docker networks
  ✓ systemd services
  ✓ Cron jobs

Preserved:
  ✓ /srv/nemoclaw/config    (NemoClaw configuration)
  ✓ /srv/nemoclaw/models    (Ollama models)
  ✓ /srv/nemoclaw/backups   (Backup files)
  ✓ /srv/nemoclaw/logs      (Service logs)
  ✓ Docker, Node.js, npm    (System packages)

Recovery Options:

1. Reinstall from scratch:
   bash scripts/setup.sh

2. Reinstall and restore from backup:
   bash scripts/setup.sh
   bash scripts/restore.sh <backup-file>

3. List available backups:
   bash scripts/backup.sh --list
   ls -lh /srv/nemoclaw/backups/

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
            --keep-backups) KEEP_BACKUPS=true; shift ;;
            --also-delete-data) DELETE_DATA=true; shift ;;
            --verbose) set -x; shift ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
    
    log_info "═════════════════════════════════════════════════════════"
    log_info "NemoClaw Destruction"
    log_info "═════════════════════════════════════════════════════════"
    
    # Confirmation
    confirm_destruction
    
    # Backup before destruction
    backup_before_destroy
    
    # Execute destruction
    stop_services
    remove_docker_resources
    remove_systemd_services
    remove_cron_jobs
    remove_packages
    
    # Verify
    verify_destruction
    
    # Delete data if requested (DANGEROUS!)
    if [[ "${DELETE_DATA:-false}" == "true" ]]; then
        log_error "Deleting /srv/nemoclaw/ (--also-delete-data flag)..."
        rm -rf /srv/nemoclaw
        log_warn "Data deleted!"
    fi
    
    # Summary
    print_summary
    
    log_success "Destruction completed at $(date)"
}

# Run main
main "$@"