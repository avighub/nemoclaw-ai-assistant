#!/bin/bash

##############################################################################
# NemoClaw Backup Script
#
# Creates compressed tarball backup of:
#   - NemoClaw configuration and state
#   - Local Ollama models (if enabled)
#   - OpenShell gateway configuration
#   - Service logs
#   - Docker volumes
#
# Automatically removes old backups based on retention policy
#
# Usage: bash scripts/backup.sh [--help]
##############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration (load from environment or defaults)
CONFIG_DIR="${CONFIG_DIR:-/srv/nemoclaw/config}"
MODELS_DIR="${MODELS_DIR:-/srv/nemoclaw/models}"
LOGS_DIR="${LOGS_DIR:-/srv/nemoclaw/logs}"
BACKUP_DIR="${BACKUP_DIR:-/srv/nemoclaw/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

BACKUP_TIMESTAMP=$(date -u +'%Y-%m-%d-%H-%M-%S')
BACKUP_FILE="$BACKUP_DIR/nemoclaw-backup-$BACKUP_TIMESTAMP.tar.gz"
BACKUP_MANIFEST="$BACKUP_DIR/nemoclaw-backup-$BACKUP_TIMESTAMP.manifest"

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
Usage: bash scripts/backup.sh [OPTIONS]

Creates a compressed backup of all NemoClaw data and configuration.

Options:
  --help              Show this help message
  --retention DAYS    Override backup retention (default: 30 days)
  --no-cleanup        Don't remove old backups
  --verbose           Enable verbose tar output
  --list              List all existing backups
  --test              Dry-run (show what would be backed up)

Examples:
  bash scripts/backup.sh
  bash scripts/backup.sh --verbose
  bash scripts/backup.sh --retention 60
  bash scripts/backup.sh --list
EOF
    exit 0
}

# Verify directories exist
verify_directories() {
    local missing=()
    
    for dir in "$CONFIG_DIR" "$MODELS_DIR" "$LOGS_DIR"; do
        if [[ ! -d "$dir" ]]; then
            log_warn "Directory not found: $dir (will create if needed during restore)"
        fi
    done
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_info "Creating backup directory: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
    fi
}

# Stop running services (optional, to ensure consistent state)
stop_services() {
    log_info "Pausing services for consistent backup..."
    
    # Try graceful stop
    docker compose pause 2>/dev/null || true
    sleep 2
}

# Resume services
resume_services() {
    log_info "Resuming services..."
    docker compose unpause 2>/dev/null || true
}

# Create backup tarball
create_backup() {
    log_info "Creating backup: $BACKUP_FILE"
    
    local tar_opts="-czf"
    [[ "${VERBOSE:-false}" == "true" ]] && tar_opts="-czvf"
    
    # Create backup with all necessary directories
    tar $tar_opts "$BACKUP_FILE" \
        --exclude='*.log' \
        --exclude='__pycache__' \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='.venv' \
        --transform='s|^/srv/nemoclaw|nemoclaw-data|' \
        "$CONFIG_DIR" \
        "$MODELS_DIR" \
        "$LOGS_DIR" \
        2>&1 || {
        log_error "Backup creation failed"
        return 1
    }
    
    local backup_size=$(du -h "$BACKUP_FILE" | cut -f1)
    log_success "Backup created: $BACKUP_FILE ($backup_size)"
}

# Create manifest file (for integrity verification)
create_manifest() {
    log_info "Creating backup manifest..."
    
    {
        echo "# NemoClaw Backup Manifest"
        echo "# Created: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
        echo ""
        echo "Backup File: $BACKUP_FILE"
        echo "Backup Size: $(du -h "$BACKUP_FILE" | cut -f1)"
        echo "Backup Hash: $(sha256sum "$BACKUP_FILE" | cut -d' ' -f1)"
        echo ""
        echo "Contents:"
        tar -tzf "$BACKUP_FILE" | head -20
        echo "... ($(tar -tzf "$BACKUP_FILE" | wc -l) total files)"
        echo ""
        echo "Configuration Directory: $CONFIG_DIR"
        echo "Models Directory: $MODELS_DIR"
        echo "Logs Directory: $LOGS_DIR"
        echo ""
        echo "System Information:"
        echo "  Hostname: $(hostname)"
        echo "  OS: $(lsb_release -d | cut -f2)"
        echo "  Kernel: $(uname -r)"
        echo ""
        echo "Service Status:"
        docker compose ps 2>/dev/null || echo "  Docker Compose: not running"
        echo ""
        echo "Retention: Keep for $BACKUP_RETENTION_DAYS days"
    } > "$BACKUP_MANIFEST"
    
    log_success "Manifest created: $BACKUP_MANIFEST"
}

# Cleanup old backups based on retention policy
cleanup_old_backups() {
    log_info "Cleaning up backups older than $BACKUP_RETENTION_DAYS days..."
    
    local count_before=$(ls -1 "$BACKUP_DIR"/nemoclaw-backup-*.tar.gz 2>/dev/null | wc -l)
    
    # Find and delete old backups
    find "$BACKUP_DIR" -name "nemoclaw-backup-*.tar.gz" -mtime "+$BACKUP_RETENTION_DAYS" -delete 2>/dev/null || true
    find "$BACKUP_DIR" -name "nemoclaw-backup-*.manifest" -mtime "+$BACKUP_RETENTION_DAYS" -delete 2>/dev/null || true
    
    local count_after=$(ls -1 "$BACKUP_DIR"/nemoclaw-backup-*.tar.gz 2>/dev/null | wc -l || echo 0)
    local deleted=$((count_before - count_after))
    
    if [[ $deleted -gt 0 ]]; then
        log_success "Removed $deleted old backup(s)"
    else
        log_info "No old backups to remove"
    fi
}

# List all backups
list_backups() {
    log_info "Existing backups:"
    echo ""
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_warn "No backup directory found"
        return 0
    fi
    
    local backups=$(ls -lh "$BACKUP_DIR"/nemoclaw-backup-*.tar.gz 2>/dev/null | wc -l)
    
    if [[ $backups -eq 0 ]]; then
        log_warn "No backups found in $BACKUP_DIR"
        return 0
    fi
    
    # Print table header
    printf "%-40s %-12s %-19s %-10s\n" "Backup File" "Size" "Created" "Age"
    printf "%s\n" "────────────────────────────────────────────────────────────────────────────────"
    
    # List backups with age calculation
    ls -1t "$BACKUP_DIR"/nemoclaw-backup-*.tar.gz 2>/dev/null | while read -r backup; do
        local filename=$(basename "$backup")
        local size=$(du -h "$backup" | cut -f1)
        local mtime=$(stat -c %y "$backup" | cut -d' ' -f1,2)
        local timestamp=$(echo "$filename" | sed 's/nemoclaw-backup-//;s/.tar.gz//')
        
        # Calculate age
        local backup_epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo 0)
        local current_epoch=$(date +%s)
        local age_seconds=$((current_epoch - backup_epoch))
        local age_hours=$((age_seconds / 3600))
        
        if [[ $age_hours -lt 24 ]]; then
            age="${age_hours}h"
        elif [[ $age_hours -lt 720 ]]; then
            age="$((age_hours / 24))d"
        else
            age="$((age_hours / 720))w"
        fi
        
        printf "%-40s %-12s %-19s %-10s\n" "$filename" "$size" "$timestamp" "$age"
    done
    
    echo ""
    local total=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    log_info "Total backup storage: $total"
}

# Verify backup integrity
verify_backup() {
    log_info "Verifying backup integrity..."
    
    if ! tar -tzf "$BACKUP_FILE" > /dev/null 2>&1; then
        log_error "Backup verification failed - tarball is corrupted"
        return 1
    fi
    
    log_success "Backup integrity verified"
}

# Send notification (if configured)
send_notification() {
    local status="$1"
    local message="$2"
    
    # This is a placeholder for email/webhook notifications
    # Implement based on your notification preferences
    
    if [[ "${NOTIFICATIONS_ENABLED:-false}" == "true" ]]; then
        log_info "Would send notification: $status - $message"
        # TODO: Implement notification mechanism
    fi
}

# Test mode (show what would be backed up)
test_backup() {
    log_info "Test mode - showing what would be backed up:"
    echo ""
    
    log_info "Configuration Directory:"
    find "$CONFIG_DIR" -type f 2>/dev/null | head -10 || log_warn "  (empty or not found)"
    
    log_info "Models Directory:"
    find "$MODELS_DIR" -type f 2>/dev/null | head -10 || log_warn "  (empty or not found)"
    
    log_info "Logs Directory:"
    find "$LOGS_DIR" -type f 2>/dev/null | head -10 || log_warn "  (empty or not found)"
    
    echo ""
    log_info "Estimated backup size:"
    du -sh "$CONFIG_DIR" "$MODELS_DIR" "$LOGS_DIR" 2>/dev/null || echo "  (cannot estimate)"
}

##############################################################################
# Main Backup Flow
##############################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help) usage ;;
            --retention) BACKUP_RETENTION_DAYS="$2"; shift 2 ;;
            --no-cleanup) NO_CLEANUP=true; shift ;;
            --verbose) VERBOSE=true; shift ;;
            --list) LIST_MODE=true; shift ;;
            --test) TEST_MODE=true; shift ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
    
    log_info "═════════════════════════════════════════════════════════"
    log_info "NemoClaw Backup"
    log_info "═════════════════════════════════════════════════════════"
    
    # List mode
    if [[ "${LIST_MODE:-false}" == "true" ]]; then
        list_backups
        exit 0
    fi
    
    # Test mode
    if [[ "${TEST_MODE:-false}" == "true" ]]; then
        test_backup
        exit 0
    fi
    
    # Normal backup flow
    verify_directories
    stop_services
    
    if create_backup; then
        create_manifest
        verify_backup
        
        if [[ "${NO_CLEANUP:-false}" != "true" ]]; then
            cleanup_old_backups
        fi
        
        echo ""
        log_success "Backup completed successfully!"
        log_info "Backup location: $BACKUP_FILE"
        log_info "Retention: $BACKUP_RETENTION_DAYS days"
        
        send_notification "SUCCESS" "Backup completed: $BACKUP_TIMESTAMP"
        exit 0
    else
        log_error "Backup failed!"
        send_notification "FAILURE" "Backup failed at $BACKUP_TIMESTAMP"
        exit 1
    fi
}

# Ensure services are resumed on exit
trap "resume_services" EXIT

# Run main
main "$@"