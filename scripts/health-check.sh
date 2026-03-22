#!/bin/bash

##############################################################################
# NemoClaw Health Check Script
#
# Verifies system status:
#   - Services running
#   - Directories present
#   - Disk/memory usage
#   - Container health
#   - Backup status
#   - Network connectivity
#
# Usage: bash scripts/health-check.sh [--help]
##############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;37m'
NC='\033[0m'

# Configuration
CONFIG_DIR="${CONFIG_DIR:-/srv/nemoclaw/config}"
MODELS_DIR="${MODELS_DIR:-/srv/nemoclaw/models}"
LOGS_DIR="${LOGS_DIR:-/srv/nemoclaw/logs}"
BACKUP_DIR="${BACKUP_DIR:-/srv/nemoclaw/backups}"

WARN_DISK_PERCENT=80
WARN_MEMORY_PERCENT=80
WARN_BACKUP_AGE_HOURS=48

##############################################################################
# Helper Functions
##############################################################################

print_header() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  NemoClaw Health Check - $(date '+%Y-%m-%d %H:%M:%S UTC')              ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    local title="$1"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${title}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

check_status() {
    local status="$1"
    if [[ "$status" == "ok" ]] || [[ "$status" == "running" ]] || [[ "$status" == "true" ]]; then
        echo -e "${GREEN}✓${NC}"
        return 0
    elif [[ "$status" == "warn" ]] || [[ "$status" == "high" ]]; then
        echo -e "${YELLOW}⚠${NC}"
        return 1
    else
        echo -e "${RED}✗${NC}"
        return 2
    fi
}

usage() {
    cat << EOF
Usage: bash scripts/health-check.sh [OPTIONS]

Checks NemoClaw system health and provides diagnostics.

Options:
  --help              Show this help message
  --verbose           Show detailed information
  --json              Output results as JSON
  --warnings-only     Only show warnings and errors
  --fix               Attempt to fix common issues

Examples:
  bash scripts/health-check.sh
  bash scripts/health-check.sh --verbose
  bash scripts/health-check.sh --warnings-only
EOF
    exit 0
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Get filesystem usage
get_disk_usage() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        echo "0"
        return 1
    fi
    
    df "$path" 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//'
}

# Get memory usage
get_memory_usage() {
    local total=$(free -b | awk 'NR==2 {print $2}')
    local used=$(free -b | awk 'NR==2 {print $3}')
    
    if [[ $total -gt 0 ]]; then
        echo $((used * 100 / total))
    else
        echo "0"
    fi
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ $bytes -lt 1048576 ]]; then
        echo "$((bytes / 1024))KB"
    elif [[ $bytes -lt 1073741824 ]]; then
        echo "$((bytes / 1048576))MB"
    else
        echo "$((bytes / 1073741824))GB"
    fi
}

##############################################################################
# Health Checks
##############################################################################

check_commands() {
    print_section "System Commands"
    
    local commands=("docker" "node" "npm" "nemoclaw" "openshell" "systemctl")
    local all_ok=true
    
    for cmd in "${commands[@]}"; do
        printf "  %-20s " "$cmd:"
        if command_exists "$cmd"; then
            local version=$($cmd --version 2>&1 | head -1)
            echo -e "${GREEN}✓${NC} ($version)"
        else
            echo -e "${RED}✗${NC} (not found)"
            all_ok=false
        fi
    done
    
    echo ""
}

check_directories() {
    print_section "Persistent Storage"
    
    local dirs=("$CONFIG_DIR" "$MODELS_DIR" "$LOGS_DIR" "$BACKUP_DIR")
    local all_ok=true
    
    for dir in "${dirs[@]}"; do
        printf "  %-30s " "$(basename $dir):"
        if [[ -d "$dir" ]]; then
            local size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            local file_count=$(find "$dir" -type f 2>/dev/null | wc -l)
            echo -e "${GREEN}✓${NC} ($size, $file_count files)"
        else
            echo -e "${RED}✗${NC} (not found)"
            all_ok=false
        fi
    done
    
    echo ""
}

check_docker() {
    print_section "Docker Services"
    
    if ! command_exists docker; then
        echo -e "  ${RED}✗${NC} Docker not installed"
        return 1
    fi
    
    # Check Docker daemon
    printf "  %-30s " "Docker daemon:"
    if docker ps &> /dev/null; then
        echo -e "${GREEN}✓${NC} (running)"
    else
        echo -e "${RED}✗${NC} (not responding)"
        return 1
    fi
    
    # Check running containers
    printf "  %-30s " "Containers running:"
    local count=$(docker ps --format "{{.Names}}" | wc -l)
    echo -e "${GREEN}✓${NC} ($count containers)"
    
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null | sed 's/^/    /'
    
    echo ""
}

check_services() {
    print_section "NemoClaw Services"
    
    # Check nemoclaw systemd service
    printf "  %-30s " "nemoclaw.service:"
    if systemctl is-active nemoclaw.service &> /dev/null; then
        echo -e "${GREEN}✓${NC} (active)"
    elif systemctl is-enabled nemoclaw.service &> /dev/null; then
        echo -e "${YELLOW}⚠${NC} (enabled but not running)"
    else
        echo -e "${YELLOW}⚠${NC} (not configured)"
    fi
    
    # Check OpenShell gateway
    printf "  %-30s " "OpenShell gateway:"
    if command_exists openshell; then
        if openshell sandbox list &> /dev/null; then
            local sandbox_count=$(openshell sandbox list 2>/dev/null | grep -c "running" || echo 0)
            echo -e "${GREEN}✓${NC} ($sandbox_count running)"
        else
            echo -e "${YELLOW}⚠${NC} (not responding)"
        fi
    else
        echo -e "${RED}✗${NC} (not installed)"
    fi
    
    # Check Docker Compose services
    printf "  %-30s " "Docker Compose:"
    if docker compose ps &> /dev/null 2>&1; then
        local dc_count=$(docker compose ps --services 2>/dev/null | wc -l)
        echo -e "${GREEN}✓${NC} ($dc_count services defined)"
    else
        echo -e "${YELLOW}⚠${NC} (not configured)"
    fi
    
    echo ""
}

check_resources() {
    print_section "System Resources"
    
    # Memory usage
    printf "  %-30s " "Memory Usage:"
    local mem_usage=$(get_memory_usage)
    if [[ $mem_usage -gt $WARN_MEMORY_PERCENT ]]; then
        echo -e "${RED}HIGH${NC} ($mem_usage%)"
    elif [[ $mem_usage -gt 70 ]]; then
        echo -e "${YELLOW}MODERATE${NC} ($mem_usage%)"
    else
        echo -e "${GREEN}OK${NC} ($mem_usage%)"
    fi
    
    # Show memory details
    free -h 2>/dev/null | sed 's/^/    /'
    
    # Disk usage
    printf "\n  %-30s " "Disk Usage (/):"
    local disk_usage=$(get_disk_usage "/")
    if [[ $disk_usage -gt $WARN_DISK_PERCENT ]]; then
        echo -e "${RED}HIGH${NC} ($disk_usage%)"
    elif [[ $disk_usage -gt 70 ]]; then
        echo -e "${YELLOW}MODERATE${NC} ($disk_usage%)"
    else
        echo -e "${GREEN}OK${NC} ($disk_usage%)"
    fi
    
    # Show disk details
    df -h / 2>/dev/null | sed 's/^/    /'
    
    # CPU usage
    printf "\n  %-30s " "CPU Usage:"
    if command -v uptime &> /dev/null; then
        local load=$(uptime | grep -oP 'load average: \K[^ ]*')
        echo -e "${GREEN}OK${NC} (load: $load)"
    else
        echo -e "${GRAY}?${NC} (unable to determine)"
    fi
    
    echo ""
}

check_backups() {
    print_section "Backup Status"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo -e "  ${YELLOW}⚠${NC} Backup directory not found: $BACKUP_DIR"
        echo ""
        return 1
    fi
    
    local backup_count=$(ls -1 "$BACKUP_DIR"/nemoclaw-backup-*.tar.gz 2>/dev/null | wc -l)
    
    printf "  %-30s " "Backups available:"
    if [[ $backup_count -gt 0 ]]; then
        echo -e "${GREEN}✓${NC} ($backup_count backups)"
    else
        echo -e "${YELLOW}⚠${NC} (no backups found)"
    fi
    
    # Show latest backup
    if [[ $backup_count -gt 0 ]]; then
        printf "  %-30s " "Latest backup:"
        local latest=$(ls -1t "$BACKUP_DIR"/nemoclaw-backup-*.tar.gz 2>/dev/null | head -1)
        local latest_name=$(basename "$latest")
        local latest_age=$(($(date +%s) - $(stat -c %Y "$latest")))
        local latest_age_hours=$((latest_age / 3600))
        local size=$(du -h "$latest" | cut -f1)
        
        if [[ $latest_age_hours -lt $WARN_BACKUP_AGE_HOURS ]]; then
            echo -e "${GREEN}✓${NC} ($latest_name, $size, ${latest_age_hours}h ago)"
        else
            echo -e "${YELLOW}⚠${NC} ($latest_name, $size, ${latest_age_hours}h ago)"
        fi
    fi
    
    # Storage used
    local backup_storage=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    printf "  %-30s " "Backup storage:"
    echo "  $backup_storage"
    
    echo ""
}

check_network() {
    print_section "Network Connectivity"
    
    # Check general internet
    printf "  %-30s " "Internet (8.8.8.8):"
    if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}⚠${NC} (unreachable)"
    fi
    
    # Check NVIDIA API endpoint
    printf "  %-30s " "NVIDIA API (api.nvcf.com):"
    if timeout 2 bash -c "echo > /dev/tcp/api.nvcf.com/443" 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}⚠${NC} (unreachable)"
    fi
    
    # Check Ollama if running
    if docker ps 2>/dev/null | grep -q ollama; then
        printf "  %-30s " "Ollama API (localhost:11434):"
        if timeout 2 curl -s http://localhost:11434/api/tags &> /dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${YELLOW}⚠${NC} (unreachable)"
        fi
    fi
    
    echo ""
}

check_logs() {
    print_section "Recent Errors (Last 5)"
    
    local error_count=0
    
    # Check systemd logs
    if systemctl is-enabled nemoclaw.service &> /dev/null; then
        local errors=$(journalctl -u nemoclaw.service -p err -n 5 --no-pager 2>/dev/null)
        if [[ -n "$errors" ]]; then
            echo -e "${RED}Systemd Errors:${NC}"
            echo "$errors" | sed 's/^/  /'
            error_count=$((error_count + 1))
        fi
    fi
    
    # Check Docker logs
    if docker compose logs --tail 10 2>/dev/null | grep -i error; then
        echo -e "${RED}Docker Errors:${NC}"
        docker compose logs --tail 5 2>/dev/null | grep -i error | sed 's/^/  /'
        error_count=$((error_count + 1))
    fi
    
    if [[ $error_count -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} No recent errors found"
    fi
    
    echo ""
}

##############################################################################
# Main Flow
##############################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help) usage ;;
            --verbose) VERBOSE=true; shift ;;
            --json) JSON=true; shift ;;
            --warnings-only) WARNINGS_ONLY=true; shift ;;
            --fix) FIX=true; shift ;;
            *) shift ;;
        esac
    done
    
    print_header
    
    check_commands
    check_directories
    check_docker
    check_services
    check_resources
    check_backups
    check_network
    check_logs
    
    # Final summary
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Health check complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  • View detailed logs: journalctl -u nemoclaw -f"
    echo "  • Check Docker status: docker compose ps"
    echo "  • Connect to sandbox: nemoclaw my-assistant connect"
    echo "  • Create backup: bash scripts/backup.sh"
    echo ""
}

main "$@"