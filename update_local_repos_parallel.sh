#!/opt/homebrew/bin/bash

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_DIR="${CODE_DIR:-$HOME/code}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/logs/git_update_$(date +%Y%m%d_%H%M%S).log}"
SKIP_DIRS="${SKIP_DIRS:-logs .DS_Store automated-git-sync}"
DEFAULT_BRANCHES="${DEFAULT_BRANCHES:-main master}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
BATCH_SIZE="${BATCH_SIZE:-3}"
JOB_TIMEOUT="${JOB_TIMEOUT:-300}"

# Source repository-specific commands if config file exists
REPO_COMMANDS_FILE="$SCRIPT_DIR/.repo-commands.sh"
if [[ -f "$REPO_COMMANDS_FILE" ]]; then
    # shellcheck source=.repo-commands.sh
    source "$REPO_COMMANDS_FILE"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Global arrays for tracking jobs and results
declare -a job_pids=()
declare -a job_repos=()
declare -a job_logs=()
declare -A repo_results=()

# Mutex for synchronized logging
LOG_MUTEX="/tmp/git_update_log_mutex_$$"

# Synchronized logging functions
log_sync() {
    local level="$1"
    local repo="${2:-MAIN}"
    shift 2
    local message="$*"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local prefix=""
    
    # Color coding by repository for parallel output
    case "$(($(echo "$repo" | sum | cut -d' ' -f1) % 6))" in
        0) prefix="${RED}[$repo]${NC}" ;;
        1) prefix="${GREEN}[$repo]${NC}" ;;
        2) prefix="${YELLOW}[$repo]${NC}" ;;
        3) prefix="${BLUE}[$repo]${NC}" ;;
        4) prefix="${CYAN}[$repo]${NC}" ;;
        5) prefix="${MAGENTA}[$repo]${NC}" ;;
    esac
    
    # Use file locking for synchronized output (macOS compatible)
    # Create a simple file-based mutex for synchronized logging
    local lock_acquired=false
    local attempts=0
    
    # Try to acquire lock (simple file-based approach)
    while [[ $attempts -lt 50 ]]; do
        if (set -C; echo $$ > "$LOG_MUTEX") 2>/dev/null; then
            lock_acquired=true
            break
        fi
        sleep 0.1
        attempts=$((attempts + 1))
    done
    
    # Output the message
    case "$level" in
        ERROR) echo -e "$prefix ${RED}[ERROR]${NC} $message" ;;
        WARN)  echo -e "$prefix ${YELLOW}[WARN]${NC} $message" ;;
        INFO)  echo -e "$prefix ${GREEN}[INFO]${NC} $message" ;;
        DEBUG) [[ "$VERBOSE" == "true" ]] && echo -e "$prefix ${BLUE}[DEBUG]${NC} $message" ;;
        DRY)   echo -e "$prefix ${CYAN}[DRY-RUN]${NC} $message" ;;
    esac
    
    # Also log to file if log directory exists
    if [[ -d "$(dirname "$LOG_FILE")" ]]; then
        echo "[$timestamp] [$repo] [$level] $message" >> "$LOG_FILE"
    fi
    
    # Release lock
    if [[ "$lock_acquired" == "true" ]]; then
        rm -f "$LOG_MUTEX" 2>/dev/null || true
    fi
}

# Main log function for non-repo specific messages
log() {
    log_sync "$1" "MAIN" "${@:2}"
}

# Error handling for parallel jobs
handle_job_error() {
    local repo="$1"
    local exit_code="$2"
    local line_number="$3"
    log_sync ERROR "$repo" "Job failed at line $line_number with exit code $exit_code"
}

# Check if directory is a git repository
is_git_repo() {
    [[ -d ".git" ]] || git rev-parse --git-dir > /dev/null 2>&1
}

# Check if remote exists and is accessible
check_remote() {
    local remote="${1:-origin}"
    if ! git remote get-url "$remote" > /dev/null 2>&1; then
        return 1
    fi
    
    # Quick connectivity check - timeout after 10 seconds
    if ! timeout 10 git ls-remote --exit-code "$remote" > /dev/null 2>&1; then
        return 1
    fi
    
    return 0
}

# Get the default branch for the repository
get_default_branch() {
    local remote="${1:-origin}"
    
    # Try to get the default branch from remote
    if check_remote "$remote"; then
        local default_branch
        default_branch=$(git symbolic-ref "refs/remotes/$remote/HEAD" 2>/dev/null | sed "s@^refs/remotes/$remote/@@" || true)
        
        if [[ -n "$default_branch" ]] && git rev-parse --verify "$default_branch" > /dev/null 2>&1; then
            echo "$default_branch"
            return 0
        fi
    fi
    
    # Fall back to checking which default branches exist locally
    for branch in $DEFAULT_BRANCHES; do
        if git rev-parse --verify "$branch" > /dev/null 2>&1; then
            echo "$branch"
            return 0
        fi
    done
    
    return 1
}

# Check for various types of local changes
has_local_changes() {
    # Check for uncommitted changes (staged and unstaged)
    if [[ $(git status --porcelain | wc -l) -gt 0 ]]; then
        return 0
    fi
    
    # Check for unpushed commits if remote exists
    if check_remote origin >/dev/null 2>&1; then
        local current_branch
        if current_branch=$(git symbolic-ref --short HEAD 2>/dev/null); then
            local upstream="origin/$current_branch"
            if git rev-parse --verify "$upstream" >/dev/null 2>&1; then
                local ahead_count
                ahead_count=$(git rev-list --count "$upstream..HEAD" 2>/dev/null || echo "0")
                if [[ "$ahead_count" -gt 0 ]]; then
                    return 0
                fi
            fi
        fi
    fi
    
    return 1
}

# Safely stash changes
safe_stash() {
    local repo_name="$1"
    if [[ $(git status --porcelain | wc -l) -gt 0 ]]; then
        local stash_name="auto-stash-$(date +%Y%m%d_%H%M%S)"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_sync DRY "$repo_name" "Would stash changes as: $stash_name"
            echo "$stash_name"
            return 0
        fi
        
        if git stash push -m "$stash_name" --include-untracked > /dev/null 2>&1; then
            log_sync INFO "$repo_name" "  Stashed changes as: $stash_name"
            echo "$stash_name"
            return 0
        else
            log_sync ERROR "$repo_name" "  Failed to stash changes"
            return 1
        fi
    fi
    return 0
}

# Safely restore stashed changes
safe_stash_pop() {
    local repo_name="$1"
    local stash_name="$2"
    if [[ -n "$stash_name" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_sync DRY "$repo_name" "Would restore stashed changes: $stash_name"
            return 0
        fi
        
        if git stash list | grep -q "$stash_name"; then
            if git stash pop > /dev/null 2>&1; then
                log_sync INFO "$repo_name" "  Restored stashed changes: $stash_name"
            else
                log_sync WARN "$repo_name" "  Could not auto-restore stash: $stash_name (may have conflicts)"
                log_sync WARN "$repo_name" "  Manual restore: git stash apply stash@{0}"
            fi
        fi
    fi
}

# Execute repository-specific commands
# Repository-specific commands function
# This default implementation does nothing - users can override by creating .repo-commands.sh
run_repo_commands() {
    local repo_name="$1"
    log_sync DEBUG "$repo_name" "  No specific commands configured for repository: $repo_name"
}

# Process a single repository (runs in parallel)
# This function performs the complete git sync workflow for one repository.
# It runs as a background job and communicates results via log files.
#
# Parameters:
#   $1: repo_dir - Full path to repository directory
#   $2: job_log - Path to log file for this job's output
#
# Workflow:
#   1. Setup job environment and error handling
#   2. Validate repository and get current state
#   3. Safely preserve local changes (stash if needed)
#   4. Switch to default branch and pull latest changes
#   5. Run repository-specific commands (e.g., bundle install)
#   6. Restore original branch and local changes
#   7. Report success/failure status
process_repo_job() {
    local repo_dir="$1"
    local job_log="$2"
    local repo_name=$(basename "$repo_dir")
    
    # ============================================================================
    # STEP 1: Job Setup and Error Handling
    # ============================================================================
    
    # Redirect all stdout/stderr to job log file for parallel output management
    exec > "$job_log" 2>&1
    
    # Set up error handler specific to this background job
    # If any command fails, log the error and mark job as failed
    trap 'handle_job_error "$repo_name" $? $LINENO; exit 1' ERR
    
    log_sync INFO "$repo_name" "Starting parallel processing"
    
    # ============================================================================
    # STEP 2: Repository Validation and Initial State
    # ============================================================================
    
    # Change to repository directory - critical step that must succeed
    cd "$repo_dir" || {
        log_sync ERROR "$repo_name" "Cannot enter directory: $repo_dir"
        echo "FAILED" > "${job_log}.result"
        exit 1
    }
    
    # Verify this is actually a git repository before attempting git operations
    # Prevents errors if directory exists but isn't version controlled
    if ! is_git_repo; then
        log_sync WARN "$repo_name" "  Not a git repository, skipping"
        echo "SKIPPED" > "${job_log}.result"
        exit 0
    fi
    
    # Get current branch name to restore later
    # Skip repositories in detached HEAD state to avoid complications
    local current_branch
    if ! current_branch=$(git symbolic-ref --short HEAD 2>/dev/null); then
        log_sync WARN "$repo_name" "  In detached HEAD state, skipping"
        echo "SKIPPED" > "${job_log}.result"
        exit 0
    fi
    
    log_sync INFO "$repo_name" "  Current branch: $current_branch"
    
    # ============================================================================
    # STEP 3: Local Changes Protection
    # ============================================================================
    
    # Check for any local modifications that need preservation
    # This includes uncommitted changes, staged files, and unpushed commits
    local stash_name=""
    if has_local_changes; then
        log_sync INFO "$repo_name" "  Found local changes (uncommitted or unpushed)"
        
        # Only stash uncommitted changes (staged + unstaged files)
        # Unpushed commits are preserved by staying on the current branch
        if [[ $(git status --porcelain | wc -l) -gt 0 ]]; then
            # Create a timestamped stash to safely preserve work
            if stash_name=$(safe_stash "$repo_name"); then
                log_sync DEBUG "$repo_name" "  Uncommitted changes stashed successfully"
            else
                # If stashing fails, abort to prevent data loss
                log_sync ERROR "$repo_name" "  Failed to stash changes, skipping repository"
                echo "FAILED" > "${job_log}.result"
                exit 1
            fi
        fi
    else
        log_sync INFO "$repo_name" "  No local changes detected"
    fi
    
    # ============================================================================
    # STEP 4: Default Branch Operations (Sync with Remote)
    # ============================================================================
    
    # Attempt to identify and switch to the repository's default branch
    # This is where we'll pull the latest changes from remote
    local default_branch
    if default_branch=$(get_default_branch); then
        log_sync INFO "$repo_name" "  Default branch: $default_branch"
        
        # Switch to default branch if we're not already on it
        # This allows us to pull the latest changes safely
        if [[ "$current_branch" != "$default_branch" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_sync DRY "$repo_name" "Would checkout: $default_branch"
            else
                if git checkout "$default_branch" > /dev/null 2>&1; then
                    log_sync INFO "$repo_name" "  Switched to $default_branch"
                else
                    # If checkout fails, restore stash and abort
                    log_sync ERROR "$repo_name" "  Failed to checkout $default_branch"
                    safe_stash_pop "$repo_name" "$stash_name"
                    echo "FAILED" > "${job_log}.result"
                    exit 1
                fi
            fi
        fi
        
        # Pull latest changes from remote origin
        # This updates the default branch with upstream changes
        if check_remote origin; then
            log_sync INFO "$repo_name" "  Pulling latest changes from origin..."
            if [[ "$DRY_RUN" == "true" ]]; then
                log_sync DRY "$repo_name" "Would run: git pull"
            else
                # Use timeout to prevent hanging on network issues
                local pull_output
                if pull_output=$(timeout 60 git pull 2>&1); then
                    if echo "$pull_output" | grep -q "Already up to date"; then
                        log_sync INFO "$repo_name" "  Already up to date"
                    else
                        log_sync INFO "$repo_name" "  Pull completed successfully"
                    fi
                else
                    # Pull failed - log but continue (network issues are common)
                    log_sync WARN "$repo_name" "  Pull failed or timed out: continuing with local state"
                fi
            fi
        else
            # No accessible remote - skip pulling (offline development scenario)
            log_sync WARN "$repo_name" "  No accessible remote origin, skipping pull"
        fi
    else
        # No identifiable default branch - stay on current branch
        log_sync INFO "$repo_name" "  No identifiable default branch, staying on $current_branch"
    fi
    
    # ============================================================================
    # STEP 5: Repository-Specific Maintenance Commands
    # ============================================================================
    
    # Execute custom commands based on repository type
    # Examples: bundle install, npm install, database migrations, etc.
    run_repo_commands "$repo_name"
    
    # ============================================================================
    # STEP 6: Restore Original Working State
    # ============================================================================
    
    # Switch back to the original branch if we changed it
    # This ensures the user's working environment is preserved
    if [[ -n "${default_branch:-}" ]] && [[ "$current_branch" != "$default_branch" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_sync DRY "$repo_name" "Would checkout: $current_branch"
        else
            if git checkout "$current_branch" > /dev/null 2>&1; then
                log_sync INFO "$repo_name" "  Switched back to $current_branch"
            else
                # Checkout failure is serious but not fatal - user can fix manually
                log_sync WARN "$repo_name" "  Could not switch back to $current_branch"
                log_sync WARN "$repo_name" "  Manual checkout required: git checkout $current_branch"
            fi
        fi
    fi
    
    # Restore any stashed changes to preserve user's work-in-progress
    if [[ -n "$stash_name" ]]; then
        safe_stash_pop "$repo_name" "$stash_name"
    fi
    
    # ============================================================================
    # STEP 7: Job Completion and Status Reporting
    # ============================================================================
    
    log_sync INFO "$repo_name" "  Repository $repo_name processed successfully"
    
    # Write success status for parent process to read
    echo "SUCCESS" > "${job_log}.result"
    exit 0
}

# Wait for a batch of jobs to complete
# This function manages parallel job synchronization, collecting results from
# background processes and handling timeouts. It ensures no job runs indefinitely
# and properly cleans up resources.
#
# Global variables used:
#   - job_pids[]: Array of background process IDs
#   - job_repos[]: Array of repository names corresponding to PIDs
#   - job_logs[]: Array of log file paths for each job
#   - repo_results[]: Associative array storing final status for each repo
#
# Process:
#   1. Wait for each background job to complete (with timeout)
#   2. Collect exit status and result files
#   3. Handle timeouts by killing stuck processes
#   4. Clean up temporary files and reset tracking arrays
wait_for_batch() {
    log INFO "Waiting for batch of ${#job_pids[@]} repositories to complete..."
    
    local completed=0
    local total=${#job_pids[@]}
    
    # ============================================================================
    # Process Each Job in Current Batch
    # ============================================================================
    
    # Iterate through all running jobs and wait for completion
    for i in "${!job_pids[@]}"; do
        local pid="${job_pids[$i]}"
        local repo="${job_repos[$i]}"
        local job_log="${job_logs[$i]}"
        
        # ========================================================================
        # Job Completion Handling
        # ========================================================================
        
        # Wait for job to complete with configurable timeout
        # Uses tail --pid to efficiently wait without polling
        if timeout "$JOB_TIMEOUT" tail --pid="$pid" -f /dev/null 2>/dev/null; then
            # Job completed within timeout - collect exit status
            wait "$pid" 2>/dev/null || true
            completed=$((completed + 1))
            
            # ====================================================================
            # Result Collection and Status Tracking
            # ====================================================================
            
            # Read the result status written by the background job
            # Each job writes SUCCESS/FAILED/SKIPPED to a .result file
            if [[ -f "${job_log}.result" ]]; then
                repo_results["$repo"]=$(cat "${job_log}.result")
            else
                # No result file indicates unexpected termination
                repo_results["$repo"]="UNKNOWN"
            fi
            
            # ====================================================================
            # Verbose Output Display
            # ====================================================================
            
            # In verbose mode, display the complete job log
            # This shows all the detailed operations for troubleshooting
            if [[ "$VERBOSE" == "true" ]] && [[ -f "$job_log" ]]; then
                cat "$job_log"
            fi
            
            # ====================================================================
            # Cleanup Job Files
            # ====================================================================
            
            # Remove temporary log and result files to prevent accumulation
            rm -f "$job_log" "${job_log}.result" 2>/dev/null || true
            
        else
            # ====================================================================
            # Timeout Handling
            # ====================================================================
            
            # Job exceeded the configured timeout - forcibly terminate it
            log WARN "Job for $repo timed out after ${JOB_TIMEOUT}s"
            
            # Send TERM signal to background process
            # Use || true to handle cases where process already exited
            kill "$pid" 2>/dev/null || true
            
            # Mark repository as timed out for final reporting
            repo_results["$repo"]="TIMEOUT"
        fi
    done
    
    # ============================================================================
    # Batch Completion Reporting
    # ============================================================================
    
    log INFO "Batch completed: $completed/$total repositories processed"
    
    # ============================================================================
    # Reset Job Tracking Arrays
    # ============================================================================
    
    # Clear all tracking arrays for the next batch
    # This prevents mixing results between batches
    job_pids=()
    job_repos=()
    job_logs=()
}

# Show usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  -h, --help      Show this help message
  -v, --verbose   Enable verbose output
  -n, --dry-run   Show what would be done without making changes
  -d, --dir DIR   Set code directory (default: ~/code)
  -b, --batch N   Set batch size for parallel processing (default: 3)
  -t, --timeout N Set job timeout in seconds (default: 300)
  
Environment Variables:
  CODE_DIR        Directory containing git repositories (default: ~/code)
  VERBOSE         Enable verbose logging (true/false)
  DRY_RUN         Enable dry-run mode (true/false)
  BATCH_SIZE      Number of parallel jobs (default: 3)
  JOB_TIMEOUT     Timeout per repository in seconds (default: 300)
  SKIP_DIRS       Space-separated list of directories to skip

Examples:
  $0                          # Update all repos in ~/code (3 parallel)
  $0 --batch 5                # Use 5 parallel jobs
  $0 --verbose --batch 2      # Use 2 parallel jobs with verbose output
  $0 --dry-run                # Show what would be done

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE="true"
                shift
                ;;
            -n|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -d|--dir)
                CODE_DIR="$2"
                shift 2
                ;;
            -b|--batch)
                BATCH_SIZE="$2"
                shift 2
                ;;
            -t|--timeout)
                JOB_TIMEOUT="$2"
                shift 2
                ;;
            *)
                log ERROR "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Cleanup function
cleanup() {
    log INFO "Cleaning up parallel jobs..."
    
    # Kill any remaining jobs
    for pid in "${job_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    
    # Clean up log files
    for job_log in "${job_logs[@]}"; do
        rm -f "$job_log" "${job_log}.result" 2>/dev/null || true
    done
    
    # Remove mutex file
    rm -f "$LOG_MUTEX" 2>/dev/null || true
}

# Main execution
main() {
    parse_args "$@"
    
    # Set up cleanup on exit
    trap cleanup EXIT INT TERM
    
    log INFO "Starting parallel git repository update script"
    log INFO "Working directory: $CODE_DIR"
    log INFO "Batch size: $BATCH_SIZE parallel jobs"
    log INFO "Job timeout: ${JOB_TIMEOUT}s per repository"
    [[ "$DRY_RUN" == "true" ]] && log INFO "DRY RUN MODE - No changes will be made"
    [[ "$VERBOSE" == "true" ]] && log INFO "Verbose logging enabled"
    log INFO "Log file: $LOG_FILE"
    
    # Ensure we're in the correct directory
    if [[ ! -d "$CODE_DIR" ]]; then
        log ERROR "Code directory does not exist: $CODE_DIR"
        exit 1
    fi
    
    cd "$CODE_DIR" || {
        log ERROR "Cannot change to code directory: $CODE_DIR"
        exit 1
    }
    
    # Create logs directory if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "/tmp/git_update_jobs_$$"
    
    # Collect all repositories to process
    local repos_to_process=()
    local skipped_repos=0
    
    for dir in */; do
        [[ -d "$dir" ]] || continue
        
        local dir_name=$(basename "$dir")
        
        # Skip directories in skip list
        local skip=false
        for skip_dir in $SKIP_DIRS; do
            if [[ "$dir_name" == "$skip_dir" ]]; then
                skip=true
                break
            fi
        done
        
        if [[ "$skip" == "true" ]]; then
            log DEBUG "Skipping directory: $dir_name"
            skipped_repos=$((skipped_repos + 1))
            continue
        fi
        
        repos_to_process+=("$dir")
    done
    
    local total_repos=${#repos_to_process[@]}
    log INFO "Found $total_repos repositories to process, $skipped_repos skipped"
    
    if [[ $total_repos -eq 0 ]]; then
        log WARN "No repositories found to process"
        exit 0
    fi
    
    # Process repositories in batches
    local processed_count=0
    
    for repo_dir in "${repos_to_process[@]}"; do
        local repo_name=$(basename "$repo_dir")
        local job_log="/tmp/git_update_jobs_$$/${repo_name}.log"
        
        echo "$(printf '%.0s-' {1..60}) Starting $repo_name $(printf '%.0s-' {1..20})"
        
        # Start background job
        process_repo_job "$repo_dir" "$job_log" &
        local job_pid=$!
        
        # Track job
        job_pids+=("$job_pid")
        job_repos+=("$repo_name")
        job_logs+=("$job_log")
        
        processed_count=$((processed_count + 1))
        
        # If batch is full or this is the last repo, wait for completion
        if [[ ${#job_pids[@]} -eq $BATCH_SIZE ]] || [[ $processed_count -eq $total_repos ]]; then
            wait_for_batch
        fi
    done
    
    # Final statistics
    echo "$(printf '%.0s=' {1..80})"
    log INFO "Parallel git repository sync completed"
    
    local successful=0
    local failed=0
    local skipped=0
    local timeouts=0
    
    for repo in "${!repo_results[@]}"; do
        case "${repo_results[$repo]}" in
            "SUCCESS") successful=$((successful + 1)) ;;
            "FAILED") failed=$((failed + 1)) ;;
            "SKIPPED") skipped=$((skipped + 1)) ;;
            "TIMEOUT") timeouts=$((timeouts + 1)) ;;
        esac
    done
    
    log INFO "Total repositories: $total_repos"
    log INFO "Successfully processed: $successful"
    log INFO "Failed to process: $failed"
    log INFO "Skipped (not git repos): $skipped"
    log INFO "Timed out: $timeouts"
    log INFO "Batch size used: $BATCH_SIZE parallel jobs"
    
    if [[ $failed -gt 0 ]] || [[ $timeouts -gt 0 ]]; then
        log WARN "Some repositories failed to update. Check the log for details."
        exit 1
    fi
    
    log INFO "All repositories updated successfully!"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi