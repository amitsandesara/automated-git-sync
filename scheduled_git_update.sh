#!/opt/homebrew/bin/bash

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_DIR="${CODE_DIR:-$HOME/code}"
LOCK_FILE="$SCRIPT_DIR/logs/git_update.lock"
STATUS_FILE="$SCRIPT_DIR/logs/git_update_status.json"
LOG_DIR="$SCRIPT_DIR/logs"
NOTIFICATION_LOG="$LOG_DIR/scheduled_updates.log"

# Script paths
PARALLEL_SCRIPT="$SCRIPT_DIR/update_local_repos_parallel.sh"
REGULAR_SCRIPT="$SCRIPT_DIR/update_local_repos.sh"

# Default to regular script, fallback to parallel if not available
UPDATE_SCRIPT="${UPDATE_SCRIPT:-$REGULAR_SCRIPT}"
if [[ ! -x "$UPDATE_SCRIPT" ]] && [[ -x "$PARALLEL_SCRIPT" ]]; then
    UPDATE_SCRIPT="$PARALLEL_SCRIPT"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging function
log_scheduled() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        INFO)  echo -e "${GREEN}[INFO]${NC} $message" ;;
        DEBUG) echo -e "${BLUE}[DEBUG]${NC} $message" ;;
    esac
    
    # Also log to notification file
    mkdir -p "$LOG_DIR"
    echo "[$timestamp] [$level] $message" >> "$NOTIFICATION_LOG"
}

# Check if another instance is running
check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        
        # Check if the process is still running
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log_scheduled WARN "Another git update is already running (PID: $lock_pid)"
            return 1
        else
            log_scheduled INFO "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    return 0
}

# Create lock file
create_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    echo $$ > "$LOCK_FILE"
}

# Remove lock file
remove_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

# Update status file with run information
update_status() {
    local status="$1"
    local run_type="$2"
    local start_time="$3"
    local end_time="$4"
    local message="${5:-}"
    
    mkdir -p "$(dirname "$STATUS_FILE")"
    
    cat > "$STATUS_FILE" << EOF
{
    "last_run": {
        "date": "$(date -Iseconds)",
        "status": "$status",
        "type": "$run_type",
        "start_time": "$start_time",
        "end_time": "$end_time",
        "duration_seconds": $(( $(date -j -f "%Y-%m-%d %H:%M:%S" "$end_time" +%s) - $(date -j -f "%Y-%m-%d %H:%M:%S" "$start_time" +%s) )),
        "message": "$message"
    },
    "today": "$(date +%Y-%m-%d)",
    "script_version": "scheduled_v1.0"
}
EOF
}

# Check if today's update was already successful
check_todays_status() {
    if [[ ! -f "$STATUS_FILE" ]]; then
        return 1  # No status file, need to run
    fi
    
    local today=$(date +%Y-%m-%d)
    local last_success_date
    local last_status
    
    if command -v jq >/dev/null 2>&1; then
        # Use jq if available
        last_success_date=$(jq -r '.today // empty' "$STATUS_FILE" 2>/dev/null || echo "")
        last_status=$(jq -r '.last_run.status // empty' "$STATUS_FILE" 2>/dev/null || echo "")
    else
        # Fallback to grep if jq not available
        last_success_date=$(grep '"today"' "$STATUS_FILE" 2>/dev/null | sed 's/.*"today": "\([^"]*\)".*/\1/' || echo "")
        last_status=$(grep '"status"' "$STATUS_FILE" 2>/dev/null | sed 's/.*"status": "\([^"]*\)".*/\1/' || echo "")
    fi
    
    if [[ "$last_success_date" == "$today" ]] && [[ "$last_status" == "success" ]]; then
        log_scheduled INFO "Today's git update already completed successfully"
        return 0  # Already successful today
    fi
    
    return 1  # Need to run
}

# Send notification (customize as needed)
send_notification() {
    local status="$1"
    local message="$2"
    local run_type="$3"
    
    case "$status" in
        "success")
            log_scheduled INFO "✅ Git repositories updated successfully ($run_type run)"
            ;;
        "failed")
            log_scheduled ERROR "❌ Git repository update failed ($run_type run): $message"
            ;;
        "skipped")
            log_scheduled INFO "⏭️  Git repository update skipped ($run_type run): $message"
            ;;
    esac
    
    # Optional: Add system notification
    if command -v osascript >/dev/null 2>&1; then
        case "$status" in
            "success")
                osascript -e "display notification \"Git repositories updated successfully\" with title \"Scheduled Git Update\" sound name \"Glass\""
                ;;
            "failed")
                osascript -e "display notification \"Git update failed: $message\" with title \"Scheduled Git Update\" sound name \"Basso\""
                ;;
        esac
    fi
}

# Main update function
# This function orchestrates the complete update process, including fallback logic,
# status tracking, and notification sending. It's designed to be called by cron
# or manually for testing.
#
# Parameters:
#   $1: run_type - Type of run: "scheduled" (8 AM), "fallback" (9:30 AM), or "test"
#
# Returns:
#   0 on success, non-zero on failure
#
# Workflow:
#   1. Validate update script availability
#   2. Check fallback logic (skip if today already succeeded)
#   3. Execute the actual git update script
#   4. Record results and send notifications
#   5. Clean up temporary files
run_update() {
    local run_type="$1"  # "scheduled" or "fallback"
    local start_time=$(date "+%Y-%m-%d %H:%M:%S")
    
    log_scheduled INFO "Starting $run_type git repository update"
    log_scheduled INFO "Using script: $UPDATE_SCRIPT"
    
    # ============================================================================
    # STEP 1: Pre-flight Validation
    # ============================================================================
    
    # Verify the update script exists and is executable
    # This prevents silent failures when script paths are wrong
    if [[ ! -x "$UPDATE_SCRIPT" ]]; then
        local error_msg="Update script not found or not executable: $UPDATE_SCRIPT"
        log_scheduled ERROR "$error_msg"
        update_status "failed" "$run_type" "$start_time" "$(date "+%Y-%m-%d %H:%M:%S")" "$error_msg"
        send_notification "failed" "$error_msg" "$run_type"
        return 1
    fi
    
    # ============================================================================
    # STEP 2: Fallback Logic Implementation
    # ============================================================================
    
    # For fallback runs (9:30 AM), check if today's update already succeeded
    # This prevents duplicate work and unnecessary resource usage
    if [[ "$run_type" == "fallback" ]]; then
        if check_todays_status; then
            local skip_msg="Fallback skipped - today's update already successful"
            log_scheduled INFO "$skip_msg"
            update_status "skipped" "$run_type" "$start_time" "$(date "+%Y-%m-%d %H:%M:%S")" "$skip_msg"
            send_notification "skipped" "$skip_msg" "$run_type"
            return 0
        else
            log_scheduled INFO "8 AM run failed or didn't complete - proceeding with fallback"
        fi
    fi
    
    # ============================================================================
    # STEP 3: Execute Git Update Script
    # ============================================================================
    
    # Create temporary log file to capture script output
    # This allows us to include detailed error information in notifications
    local temp_log="/tmp/git_update_output_$$.log"
    local exit_code=0
    
    log_scheduled INFO "Executing git update script..."
    
    # Run the actual update script
    # Capture both stdout and stderr for complete error reporting
    if "$UPDATE_SCRIPT" > "$temp_log" 2>&1; then
        
        # ========================================================================
        # Success Path: Update Completed Successfully  
        # ========================================================================
        
        log_scheduled INFO "$run_type update completed successfully"
        local end_time=$(date "+%Y-%m-%d %H:%M:%S")
        
        # Record successful completion in status file
        update_status "success" "$run_type" "$start_time" "$end_time" "Update completed successfully"
        
        # Send success notification to user
        send_notification "success" "All repositories updated" "$run_type"
        
    else
        
        # ========================================================================
        # Failure Path: Update Script Failed
        # ========================================================================
        
        exit_code=$?
        local error_msg="Update script failed with exit code $exit_code"
        log_scheduled ERROR "$error_msg"
        
        # Include the last 20 lines of script output for debugging
        # This helps identify specific repositories or operations that failed
        if [[ -f "$temp_log" ]]; then
            log_scheduled ERROR "Script output (last 20 lines):"
            tail -20 "$temp_log" | while IFS= read -r line; do
                log_scheduled ERROR "  $line"
            done
        fi
        
        # Record failure in status file with error details
        local end_time=$(date "+%Y-%m-%d %H:%M:%S")
        update_status "failed" "$run_type" "$start_time" "$end_time" "$error_msg"
        
        # Send failure notification with error information
        send_notification "failed" "$error_msg" "$run_type"
    fi
    
    # ============================================================================
    # STEP 4: Cleanup and Return
    # ============================================================================
    
    # Remove temporary log file to prevent accumulation
    rm -f "$temp_log"
    
    return $exit_code
}

# Show status of recent runs
show_status() {
    echo "Git Repository Update Schedule Status"
    echo "===================================="
    
    if [[ -f "$STATUS_FILE" ]]; then
        if command -v jq >/dev/null 2>&1; then
            echo "Last Run Information:"
            jq -r '
                "Date: " + .last_run.date +
                "\nStatus: " + .last_run.status +
                "\nType: " + .last_run.type +
                "\nDuration: " + (.last_run.duration_seconds | tostring) + " seconds" +
                (if .last_run.message != "" then "\nMessage: " + .last_run.message else "" end)
            ' "$STATUS_FILE"
        else
            echo "Status file exists: $STATUS_FILE"
            echo "Use 'cat $STATUS_FILE' to view details"
        fi
    else
        echo "No previous runs recorded"
    fi
    
    echo -e "\nScheduled Runs Log (last 10 entries):"
    if [[ -f "$NOTIFICATION_LOG" ]]; then
        tail -10 "$NOTIFICATION_LOG"
    else
        echo "No log entries found"
    fi
    
    echo -e "\nCron Status:"
    crontab -l 2>/dev/null | grep -E "(scheduled_git_update|update_local_repos)" || echo "No cron jobs found"
}

# Install cron jobs
install_cron() {
    local temp_cron="/tmp/crontab_backup_$$.txt"
    
    # Backup existing crontab
    crontab -l > "$temp_cron" 2>/dev/null || touch "$temp_cron"
    
    # Remove any existing git update entries
    grep -v "scheduled_git_update\|update_local_repos" "$temp_cron" > "${temp_cron}.new" || touch "${temp_cron}.new"
    
    # Add new cron entries
    cat >> "${temp_cron}.new" << EOF

# Automated Git Repository Updates
# Primary run: 8:00 AM on weekdays (Mon-Fri)
0 8 * * 1-5 $SCRIPT_DIR/scheduled_git_update.sh scheduled 2>&1 | logger -t git_update

# Fallback run: 9:30 AM on weekdays (Mon-Fri) - only if 8 AM failed
30 9 * * 1-5 $SCRIPT_DIR/scheduled_git_update.sh fallback 2>&1 | logger -t git_update
EOF
    
    # Install new crontab
    crontab "${temp_cron}.new"
    
    # Cleanup
    rm -f "$temp_cron" "${temp_cron}.new"
    
    log_scheduled INFO "Cron jobs installed successfully"
    log_scheduled INFO "Primary run: 8:00 AM weekdays"
    log_scheduled INFO "Fallback run: 9:30 AM weekdays (if needed)"
    
    echo "Installed cron schedule:"
    crontab -l | grep -A2 -B1 "Git Repository Updates"
}

# Remove cron jobs
remove_cron() {
    local temp_cron="/tmp/crontab_backup_$$.txt"
    
    # Backup and filter existing crontab
    crontab -l > "$temp_cron" 2>/dev/null || touch "$temp_cron"
    grep -v "scheduled_git_update\|update_local_repos\|Git Repository Updates" "$temp_cron" > "${temp_cron}.new" || touch "${temp_cron}.new"
    
    # Install filtered crontab
    crontab "${temp_cron}.new"
    
    # Cleanup
    rm -f "$temp_cron" "${temp_cron}.new"
    
    log_scheduled INFO "Cron jobs removed successfully"
}

# Show usage
show_usage() {
    cat << EOF
Usage: $0 [COMMAND]

Commands:
  scheduled         Run the scheduled update (8 AM run)
  fallback          Run the fallback update (9:30 AM run, only if needed)
  status            Show status of recent runs and cron jobs
  install-cron      Install cron jobs for automated scheduling
  remove-cron       Remove cron jobs
  test              Test run without scheduling
  help              Show this help message

Environment Variables:
  CODE_DIR          Directory containing git repositories (default: ~/code)
  UPDATE_SCRIPT     Path to update script (default: auto-detect)

Examples:
  $0 install-cron   # Set up automated daily updates
  $0 status         # Check recent update history
  $0 test           # Run update immediately for testing
  $0 remove-cron    # Remove scheduled updates

Cron Schedule:
  - Primary: 8:00 AM weekdays (Monday-Friday)
  - Fallback: 9:30 AM weekdays (only if 8 AM run failed or didn't occur)

EOF
}

# Cleanup on exit
cleanup() {
    remove_lock
}

# Main execution
main() {
    local command="${1:-help}"
    
    # Set up cleanup
    trap cleanup EXIT INT TERM
    
    case "$command" in
        "scheduled")
            if ! check_lock; then
                exit 1
            fi
            create_lock
            run_update "scheduled"
            ;;
        "fallback")
            if ! check_lock; then
                exit 1
            fi
            create_lock
            run_update "fallback"
            ;;
        "test")
            if ! check_lock; then
                exit 1
            fi
            create_lock
            run_update "test"
            ;;
        "status")
            show_status
            ;;
        "install-cron")
            install_cron
            ;;
        "remove-cron")
            remove_cron
            ;;
        "help"|*)
            show_usage
            ;;
    esac
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi