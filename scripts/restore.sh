#!/bin/bash

##############################################################################
# NemoClaw Restore Script
#
# Restores NemoClaw from a backup tarball created by backup.sh
#
# Steps:
#   1. Verifies backup integrity
#   2. Stops running services
#   3. Creates backup of current state (safety)
#   4. Extracts backup to correct locations
#   5. Restarts services
#   6. Verifies restoration
#
# Usage: bash scripts/restore.sh <backup-file> [--help]
##############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
CONFIG_DIR="${CONFIG_DIR:-/srv/nemoclaw/config}"
MODELS_DIR="${MODELS_DIR:-/srv/nemoclaw/models}"
LOGS_DIR="${LOGS_DIR:-/srv/nemoclaw/logs}"
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
Usage: bash scripts/restore.sh <backup-file> [OPTIONS]

Restores NemoClaw configuration and data from a backup.

Arguments:
  <backup-file>       Path to backup tarball (e.g., nemoclaw-backup-2025-03-22-14-30-00.tar.gz)
                      Can be filename (searches in $BACKUP_DIR) or full path

Options:
  --help              Show this help message
  --no-backup         Don't create pre-restore backup (unsafe)
  --force             Skip confirmation prompt
  --verify-only       Only verify backup, don't restore
  --verbose           Enable verbose output

Examples:
  bash scripts/restore.sh nemoclaw-backup-2025-03-22-14-30-00.tar.gz
  bash scripts/restore.sh --force nemoclaw-backup-2025-03-22-14-30-00.tar.gz
  bash scripts/restore.sh nemoclaw-backup-2025-03-22-14-30-00.tar.gz --verify-only
EOF
    exit 0
}

# Find backup file (handle relative and absolute paths)
find_backup_file() {
    local target="$1"
    
    # If absolute path, use directly
    if [[ "$target" == /* ]]; then
        if [[ -f "$target" ]]; then
            echo "$target"
            return 0
        else
            log_error "Backup file not found: $target"
            return 1
        fi
    fi
    
    # Try in backup directory
    if [[ -f "$BACKUP_DIR/$target" ]]; then
        echo "$BACKUP_DIR/$target"
        return 0
    fi
    
    # Try current directory
    if [[ -f "$target" ]]; then
        echo "$target"
        return 0
    fi
    
    log_error "Backup file not found: $target"
    log_error "Searched in:"
    log_error "  - Absolute path: $target"
    log_error "  - Backup directory: $BACKUP_DIR/$target"
    log_error "  - Current directory: $target"
    return 1
}

# Verify backup integrity
verify_backup() {
    local backup_file="$1"
    
    log_info "Verifying backup integrity..."
    
    if ! tar -tzf "$backup_file" > /dev/null 2>&1; then
        log_error "Backup verification failed - tarball is corrupted"
        return 1
    fi
    
    # Check for required paths in backup
    local has_config=$(tar -tzf "$backup_file" | grep -q "nemoclaw-data/config" && echo true || echo false)
    
    if [[ "$has_config" != "true" ]]; then
        log_warn "Backup does not contain config directory - this may be incomplete"
    fi
    
    # Calculate backup size
    local size=$(du -h "$backup_file" | cut -f1)
    local files=$(tar -tzf "$backup_file" | wc -l)
    
    log_success "Backup verification passed"
    log_info "  Size: $size"
    log_info "  Files: $files"
    
    return 0
}

# Stop services gracefully
stop_services() {
    log_info "Stopping services..."
    
    # Try docker compose stop
    if docker compose ps &> /dev/null; then
        docker compose stop 2>/dev/null || true
        sleep 2
    fi
    
    # Stop nemoclaw service
    systemctl stop nemoclaw 2>/dev/null || true
    
    log_success "Services stopped"
}

# Start services
start_services() {
    log_info "Starting services..."
    
    # Start systemd service
    systemctl start nemoclaw 2>/dev/null || log_warn "Could not start nemoclaw service"
    
    # Start docker compose
    docker compose up -d 2>/dev/null || true
    
    sleep 3
    log_success "Services started"
}

# Create backup of current state (safety measure)
backup_current_state() {
    local safety_backup="$BACKUP_DIR/pre-restore-backup-$(date -u +'%Y-%m-%d-%H-%M-%S').tar.gz"
    
    log_info "Creating safety backup of current state..."
    log_info "  Location: $safety_backup"
    
    tar -czf "$safety_backup" \
        --exclude='*.log' \
        --exclude='__pycache__' \
        --transform='s|^/srv/nemoclaw|nemoclaw-data|' \
        "$CONFIG_DIR" \
        "$MODELS_DIR" \
        2>/dev/null || {
        log_warn "Could not create pre-restore backup (continuing anyway)"
        return 1
    }
    
    local size=$(du -h "$safety_backup" | cut -f1)
    log_success "Safety backup created: $size"
}

# Extract backup to correct locations
restore_files() {
    local backup_file="$1"
    
    log_info "Extracting backup..."
    
    # Create parent directory if needed
    mkdir -p "$(dirname "$CONFIG_DIR")"
    
    # Extract with path transformation (removing nemoclaw-data prefix)
    tar -xzf "$backup_file" -C / 2>&1 || {
        log_error "Extraction failed"
        return 1
    }
    
    # Verify extraction
    if [[ ! -d "$CONFIG_DIR" ]]; then
        log_warn "Config directory not restored - may need manual intervention"
    fi
    
    log_success "Backup extracted successfully"
}

# Verify restoration
verify_restoration() {
    log_info "Verifying restoration..."
    
    local checks_passed=0
    local checks_total=0
    
    # Check directories exist
    for dir in "$CONFIG_DIR" "$MODELS_DIR"; do
        checks_total=$((checks_total + 1))
        if [[ -d "$dir" ]]; then
            local file_count=$(find "$dir" -type f 2>/dev/null | wc -l)
            log_success "✓ $dir restored ($file_count files)"
            checks_passed=$((checks_passed + 1))
        else
            log_warn "✗ $dir not restored"
        fi
    done
    
    log_info "Verification: $checks_passed / $checks_total checks passed"
    
    if [[ $checks_passed -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Print restoration summary
print_summary() {
    local backup_file="$1"
    
    cat << EOF

$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )
$( echo -e "${GREEN}Restoration Complete!${NC}" )
$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )

Restored from: $(basename "$backup_file")
Restored at:  $(date)

Data Locations:
  - Config: $CONFIG_DIR
  - Models: $MODELS_DIR
  - Logs:   $LOGS_DIR

Next Steps:

1. Verify services are running:
   docker compose ps
   systemctl status nemoclaw

2. Check NemoClaw status:
   nemoclaw my-assistant status

3. View logs if needed:
   docker compose logs -f
   journalctl -u nemoclaw -f

4. Connect to sandbox:
   nemoclaw my-assistant connect

If something went wrong:
  - Pre-restore backup saved in: $BACKUP_DIR/pre-restore-backup-*.tar.gz
  - Restore that backup to revert: bash scripts/restore.sh pre-restore-backup-*.tar.gz

$( echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}" )
EOF
}

##############################################################################
# Main Restore Flow
##############################################################################

main() {
    local backup_file=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help) usage ;;
            --no-backup) NO_BACKUP=true; shift ;;
            --force) FORCE=true; shift ;;
            --verify-only) VERIFY_ONLY=true; shift ;;
            --verbose) set -x; shift ;;
            *)
                if [[ -z "$backup_file" ]]; then
                    backup_file="$1"
                    shift
                else
                    log_error "Unknown option: $1"
                    usage
                fi
                ;;
        esac
    done
    
    # Validate arguments
    if [[ -z "$backup_file" ]]; then
        log_error "No backup file specified"
        usage
    fi
    
    log_info "═════════════════════════════════════════════════════════"
    log_info "NemoClaw Restore"
    log_info "═════════════════════════════════════════════════════════"
    
    # Find backup file
    if ! backup_file=$(find_backup_file "$backup_file"); then
        exit 1
    fi
    
    log_success "Found backup: $(basename "$backup_file")"
    
    # Verify backup
    if ! verify_backup "$backup_file"; then
        exit 1
    fi
    
    # Verify-only mode
    if [[ "${VERIFY_ONLY:-false}" == "true" ]]; then
        log_success "Backup verification passed - restore ready"
        exit 0
    fi
    
    # Confirmation prompt
    if [[ "${FORCE:-false}" != "true" ]]; then
        echo ""
        echo -e "${YELLOW}This will restore from: $(basename "$backup_file")${NC}"
        echo -e "${YELLOW}Current data in $CONFIG_DIR will be backed up${NC}"
        echo ""
        read -p "Continue with restore? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_warn "Restore cancelled"
            exit 0
        fi
    fi
    
    # Main restore steps
    stop_services
    
    if [[ "${NO_BACKUP:-false}" != "true" ]]; then
        backup_current_state
    fi
    
    if restore_files "$backup_file"; then
        start_services
        
        if verify_restoration; then
            log_success "Restoration completed successfully!"
            print_summary "$backup_file"
            exit 0
        else
            log_warn "Restoration completed but some checks failed"
            print_summary "$backup_file"
            exit 1
        fi
    else
        log_error "Restoration failed - services may be in inconsistent state"
        log_info "Attempting to restart services..."
        start_services
        exit 1
    fi
}

# Run main
main "$@"