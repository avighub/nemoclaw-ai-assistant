#!/bin/bash

##############################################################################
# NemoClaw Backup Script (Optimized)
#
# Creates compressed tarball backup of critical NemoClaw data:
#   - NemoClaw registry & credentials (~/.nemoclaw/)
#   - OpenShell Docker volume (contains openshell.db with soul.md, conversations)
#   - Ollama models (optional, only if they exist)
#   - Service logs (optional, can skip)
#
# Smart features:
#   - Only backs up directories that have content
#   - Skips empty directories automatically
#   - Configurable with --no-* flags
#   - Shows exactly what will be backed up before creating
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

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/srv/nemoclaw/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-10}"
BACKUP_TIMESTAMP=$(date -u +'%Y-%m-%d-%H-%M-%S')
BACKUP_FILE="$BACKUP_DIR/nemoclaw-backup-$BACKUP_TIMESTAMP.tar.gz"
BACKUP_MANIFEST="$BACKUP_DIR/nemoclaw-backup-$BACKUP_TIMESTAMP.manifest"

# Options (can be overridden by flags)
INCLUDE_MODELS="true"
INCLUDE_LOGS="true"
VERBOSE="false"
DRY_RUN="false"
CLEANUP="true"

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

Creates optimized backup of critical NemoClaw data (skips empty directories).

Always backed up:
  - ~/.nemoclaw/                                    (credentials, sandbox registry)
  - Docker volume openshell-cluster-nemoclaw       (contains openshell.db with soul.md, conversations)

Conditionally backed up:
  - /srv/nemoclaw/models/                         (only if contains Ollama models)
  - /srv/nemoclaw/logs/                           (optional, can skip with --no-logs)

Options:
  --help                Show this help message
  --list                List all existing backups
  --test                Show what would be backed up (dry-run)
  --verbose             Show verbose tar output
  --no-models           Don't backup Ollama models (if present)
  --no-logs             Don't backup service logs
  --no-cleanup          Don't remove old backups
  --retention DAYS      Override retention (default: 30 days)

Examples:
  bash scripts/backup.sh                          # Full backup
  bash scripts/backup.sh --test                   # Preview what would backup
  bash scripts/backup.sh --no-models              # Skip models (if using Ollama)
  bash scripts/backup.sh --no-logs --no-models    # Minimal backup
  bash scripts/backup.sh --list                   # List existing backups
EOF
    exit 0
}

# Check if directory has content (not empty)
has_content() {
    local dir="$1"
    
    if [[ ! -d "$dir" ]]; then
        return 1  # Directory doesn't exist
    fi
    
    # Check if directory has any files
    if [[ -z "$(find "$dir" -type f 2>/dev/null)" ]]; then
        return 1  # Directory is empty
    fi
    
    return 0  # Directory has content
}

# Build list of directories to backup
build_backup_list() {
    local -a backup_items=()
    
    log_info "Determining what to backup..." >&2
    echo "" >&2
    
    # Always backup: credentials and sandbox registry
    log_info "Critical data:" >&2
    if [[ -f ~/.nemoclaw/credentials.json ]]; then
        backup_items+=("~/.nemoclaw/credentials.json")
        log_info "  ✓ ~/.nemoclaw/credentials.json" >&2
    fi
    
    if [[ -f ~/.nemoclaw/sandboxes.json ]]; then
        backup_items+=("~/.nemoclaw/sandboxes.json")
        log_info "  ✓ ~/.nemoclaw/sandboxes.json" >&2
    fi
    
    # Sandbox state (in Docker volume, contains soul.md, conversations, etc.)
    local openshell_volume="/var/lib/docker/volumes/openshell-cluster-nemoclaw/_data"
    if [[ -d "$openshell_volume" ]]; then
        backup_items+=("$openshell_volume")
        local volume_size=$(du -sh "$openshell_volume" 2>/dev/null | cut -f1)
        log_info "  ✓ Docker volume openshell-cluster-nemoclaw ($volume_size)" >&2
        log_info "    (contains openshell.db with soul.md, conversations, sandbox state)" >&2
    else
        log_warn "  ○ Docker volume not found (OpenShell may not be running)" >&2
    fi
    
    echo "" >&2
    
    # Optional: Models
    if [[ "$INCLUDE_MODELS" == "true" ]]; then
        log_info "Optional data:" >&2
        if has_content "/srv/nemoclaw/models"; then
            backup_items+=("/srv/nemoclaw/models")
            local model_size=$(du -sh "/srv/nemoclaw/models" 2>/dev/null | cut -f1)
            log_info "  ✓ /srv/nemoclaw/models ($model_size)" >&2
        else
            log_info "  ○ /srv/nemoclaw/models (empty, skipping)" >&2
        fi
    else
        log_info "Optional data:" >&2
        log_info "  ○ /srv/nemoclaw/models (--no-models flag)" >&2
    fi
    
    # Optional: Logs
    if [[ "$INCLUDE_LOGS" == "true" ]]; then
        if has_content "/srv/nemoclaw/logs"; then
            backup_items+=("/srv/nemoclaw/logs")
            log_info "  ✓ /srv/nemoclaw/logs" >&2
        else
            log_info "  ○ /srv/nemoclaw/logs (empty, skipping)" >&2
        fi
    else
        log_info "  ○ /srv/nemoclaw/logs (--no-logs flag)" >&2
    fi
    
    echo "" >&2
    
    # Return the array as string (bash doesn't return arrays)
    # Output to stdout (will be captured by $(build_backup_list))
    printf '%s\n' "${backup_items[@]}"
}

# Create backup tarball
create_backup() {
    local -a backup_items=()
    
    log_info "Calculating backup size..."
    
    # Read backup items from stdin
    while IFS= read -r item; do
        backup_items+=("$item")
    done
    
    if [[ ${#backup_items[@]} -eq 0 ]]; then
        log_error "No data to backup!"
        exit 1
    fi
    
    # Ensure backup directory exists
    mkdir -p "$BACKUP_DIR"
    
    # Build tar command
    local tar_opts="-czf"
    [[ "$VERBOSE" == "true" ]] && tar_opts="-czvf"
    
    log_info "Creating backup: $BACKUP_FILE"
    
    # Create backup (expand items, handling home directory correctly)
    local expanded_items=()
    for item in "${backup_items[@]}"; do
        expanded_items+=("${item/#\~/$HOME}")
    done
    
    tar $tar_opts "$BACKUP_FILE" \
        --exclude='*.log' \
        --exclude='__pycache__' \
        --exclude='.git' \
        --exclude='node_modules' \
        "${expanded_items[@]}" \
        2>&1 || {
        log_error "Backup creation failed"
        return 1
    }
    
    local backup_size=$(du -h "$BACKUP_FILE" | cut -f1)
    log_success "Backup created: $BACKUP_FILE ($backup_size)"
}

# Create manifest
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
        echo "Included:"
        echo "  - ~/.nemoclaw/ (credentials, sandbox registry)"
        echo "  - Docker volume openshell-cluster-nemoclaw (contains openshell.db)"
        echo "    └── soul.md, conversations, sandbox state"
        if [[ "$INCLUDE_MODELS" == "true" ]]; then
            echo "  - /srv/nemoclaw/models/ (if present)"
        fi
        if [[ "$INCLUDE_LOGS" == "true" ]]; then
            echo "  - /srv/nemoclaw/logs/ (if present)"
        fi
        echo ""
        echo "System Information:"
        echo "  Hostname: $(hostname)"
        echo "  OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown')"
        echo "  Kernel: $(uname -r)"
        echo ""
        echo "Retention: Keep for $BACKUP_RETENTION_DAYS days"
    } > "$BACKUP_MANIFEST"
    
    log_success "Manifest created: $BACKUP_MANIFEST"
}

# Cleanup old backups
cleanup_old_backups() {
    log_info "Cleaning up backups older than $BACKUP_RETENTION_DAYS days..."
    
    local count_before=$(ls -1 "$BACKUP_DIR"/nemoclaw-backup-*.tar.gz 2>/dev/null | wc -l || echo 0)
    
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

# List backups
list_backups() {
    log_info "Existing backups:"
    echo ""
    
    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -1 "$BACKUP_DIR"/nemoclaw-backup-*.tar.gz 2>/dev/null)" ]]; then
        log_warn "No backups found in $BACKUP_DIR"
        return 0
    fi
    
    ls -lh "$BACKUP_DIR"/nemoclaw-backup-*.tar.gz | awk '{
        print "  " $9 " (" $5 ")"
    }'
    
    echo ""
    log_info "To restore: bash scripts/restore.sh <backup-file>"
}

##############################################################################
# Main
##############################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help) usage ;;
            --list) list_backups; exit 0 ;;
            --test) DRY_RUN="true"; shift ;;
            --verbose) VERBOSE="true"; shift ;;
            --no-models) INCLUDE_MODELS="false"; shift ;;
            --no-logs) INCLUDE_LOGS="false"; shift ;;
            --no-cleanup) CLEANUP="false"; shift ;;
            --retention) BACKUP_RETENTION_DAYS="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
    
    log_info "═══════════════════════════════════════════════════════════"
    log_info "NemoClaw Backup (Optimized)"
    log_info "═══════════════════════════════════════════════════════════"
    echo ""
    
    # Build list of what to backup
    local backup_list
    backup_list=$(build_backup_list)
    
    echo ""
    
    # Dry-run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN: Would backup the above items"
        echo ""
        log_info "To actually create backup, run:"
        log_info "  bash scripts/backup.sh"
        exit 0
    fi
    
    # Create backup
    echo "$backup_list" | create_backup
    
    echo ""
    
    # Create manifest
    create_manifest
    
    echo ""
    
    # Cleanup old backups
    if [[ "$CLEANUP" == "true" ]]; then
        cleanup_old_backups
    else
        log_info "Skipping cleanup (--no-cleanup flag)"
    fi
    
    echo ""
    log_success "Backup completed successfully!"
}

# Run main
main "$@"