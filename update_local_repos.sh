#!/opt/homebrew/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        INFO)  echo -e "${GREEN}[INFO]${NC} $message" ;;
        DEBUG) [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $message" ;;
        DRY)   echo -e "${CYAN}[DRY-RUN]${NC} $message" ;;
    esac
    
    # Also log to file if log directory exists
    if [[ -d "$(dirname "$LOG_FILE")" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.env"

# Source configuration file if it exists
if [[ -f "$CONFIG_FILE" ]]; then
    log INFO "Loading configurations from $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    log ERROR "Configuration file not found: $CONFIG_FILE. Please create an .env file with required settings."
    exit 1
fi

# Check for required CODE_DIR variable
if [[ -z "$CODE_DIR" ]]; then
    log ERROR "CODE_DIR is not defined in $CONFIG_FILE. Please set this variable."
    exit 1
fi

# Check for required LOG_RETENTION_DAYS variable
if [[ -z "$LOG_RETENTION_DAYS" ]]; then
    log ERROR "LOG_RETENTION_DAYS is not defined in $CONFIG_FILE. Please set this variable."
    exit 1
fi

# Set defaults for optional configurations
SKIP_DIRS="${SKIP_DIRS:-logs .DS_Store automated-git-sync}"
EXCLUDED_REPOS="${EXCLUDED_REPOS:-}"
DEFAULT_BRANCHES="${DEFAULT_BRANCHES:-main master}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"

LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/logs/git_update_$(date +%Y%m%d_%H%M%S).log}"

# Error handling
handle_error() {
    local exit_code=$?
    local line_number=$1
    log ERROR "Script failed at line $line_number with exit code $exit_code"
    log ERROR "Check log file for details: $LOG_FILE"
    exit $exit_code
}

trap 'handle_error $LINENO' ERR

# Check if directory is a git repository
is_git_repo() {
    [[ -d ".git" ]] || git rev-parse --git-dir > /dev/null 2>&1
}

# Check if remote exists and is accessible
check_remote() {
    local remote="${1:-origin}"
    if ! git remote get-url "$remote" > /dev/null 2>&1; then
        log DEBUG "Remote '$remote' not found"
        return 1
    fi
    
    # Quick connectivity check - timeout after 10 seconds
    if ! timeout 10 git ls-remote --exit-code "$remote" > /dev/null 2>&1; then
        log WARN "Remote '$remote' is not accessible (network/auth issue)"
        return 1
    fi
    
    return 0
}

# Get the default branch for the repository
get_default_branch() {
  local remote="${1:-origin}"
  local ref default_branch

  # 1) Ask the remote directly (works even if you don't have the branch locally)
  ref=$(git ls-remote --symref "$remote" HEAD 2>/dev/null | awk '/^ref:/ {print $2}')
  if [[ -n "$ref" ]]; then
    default_branch="${ref#refs/heads/}"
    printf '%s\n' "$default_branch"
    return 0
  fi

  # 2) Fall back to local knowledge of remote HEAD if present
  ref=$(git symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null)
  if [[ -n "$ref" ]]; then
    printf '%s\n' "${ref#${remote}/}"
    return 0
  fi

  # 3) Parse `git remote show` (works in many setups)
  default_branch=$(git remote show "$remote" 2>/dev/null | sed -n 's/.*HEAD branch: //p')
  if [[ -n "$default_branch" ]]; then
    printf '%s\n' "$default_branch"
    return 0
  fi

  # 4) Your fallback list (use remote existence check, not local)
  for branch in $DEFAULT_BRANCHES; do
    if git ls-remote --exit-code --heads "$remote" "$branch" > /dev/null 2>&1; then
      printf '%s\n' "$branch"
      return 0
    fi
  done

  log DEBUG "No default branch found"
  return 1
}
# get_default_branch() {
#     local remote="${1:-origin}"
    
#     # Try to get the default branch from remote
#     if check_remote "$remote"; then
#         local default_branch
#         default_branch=$(git symbolic-ref "refs/remotes/$remote/HEAD" 2>/dev/null | sed "s@^refs/remotes/$remote/@@" || true)
        
#         if [[ -n "$default_branch" ]] && git rev-parse --verify "$default_branch" > /dev/null 2>&1; then
#             echo "$default_branch"
#             return 0
#         fi
#     fi
    
#     # Fall back to checking which default branches exist locally
#     for branch in $DEFAULT_BRANCHES; do
#         if git rev-parse --verify "$branch" > /dev/null 2>&1; then
#             echo "$branch"
#             return 0
#         fi
#     done
    
#     log DEBUG "No default branch found"
#     return 1
# }

# Check for various types of local changes
# This function performs comprehensive detection of any local modifications
# that need to be preserved during the sync process. It checks multiple
# types of changes to ensure nothing is lost.
#
# Types of changes detected:
#   1. Uncommitted changes (staged and unstaged files)
#   2. Unpushed commits on the current branch
#   3. Untracked files that might be important
#
# Returns:
#   0 if local changes exist, 1 if repository is clean
#
# Note: This function is conservative - it errs on the side of caution
# to prevent any potential data loss during automated sync operations.
has_local_changes() {
    # ============================================================================
    # Check for Uncommitted Changes (Staged and Unstaged)
    # ============================================================================
    
    # Use git status --porcelain for machine-readable output
    # This catches: modified files, new files, deleted files, renamed files
    if [[ $(git status --porcelain | wc -l) -gt 0 ]]; then
        log DEBUG "Found uncommitted changes (staged/unstaged files)"
        return 0  # Changes detected
    fi
    
    # ============================================================================
    # Check for Unpushed Commits (Ahead of Remote)
    # ============================================================================
    
    # Only check if we have a working remote connection
    # Prevents errors when working offline or with authentication issues
    if check_remote origin >/dev/null 2>&1; then
        local current_branch
        
        # Get current branch name - needed to check upstream relationship
        if current_branch=$(git symbolic-ref --short HEAD 2>/dev/null); then
            local upstream="origin/$current_branch"
            
            # Verify the upstream branch exists before comparing
            # Some branches may not have upstream tracking set up
            if git rev-parse --verify "$upstream" >/dev/null 2>&1; then
                local ahead_count
                
                # Count commits that exist locally but not on remote
                # This identifies unpushed work that needs preservation
                ahead_count=$(git rev-list --count "$upstream..HEAD" 2>/dev/null || echo "0")
                
                if [[ "$ahead_count" -gt 0 ]]; then
                    log DEBUG "Found $ahead_count unpushed commits on $current_branch"
                    return 0  # Unpushed commits detected
                fi
            else
                log DEBUG "No upstream branch found for $current_branch"
            fi
        fi
    else
        log DEBUG "No accessible remote - skipping unpushed commit check"
    fi
    
    # ============================================================================
    # Repository is Clean
    # ============================================================================
    
    log DEBUG "No local changes detected - repository is clean"
    return 1  # No changes found
}

# Safely stash changes
# This function creates a named stash to preserve uncommitted work during
# the sync process. It uses timestamps for unique identification and includes
# untracked files to ensure comprehensive preservation.
#
# Stash naming convention: "auto-stash-YYYYMMDD_HHMMSS"
# This makes it easy to identify automated stashes and their creation time.
#
# Features:
#   - Includes untracked files (--include-untracked)
#   - Uses descriptive timestamp-based names
#   - Supports dry-run mode for testing
#   - Comprehensive error handling
#
# Returns:
#   0 on success (outputs stash name), 1 on failure
#   If no changes exist, returns 0 without creating a stash
safe_stash() {
    # ============================================================================
    # Check if Stashing is Necessary
    # ============================================================================
    
    # Only stash if there are actually changes to preserve
    # This prevents creating empty stashes that confuse users later
    if [[ $(git status --porcelain | wc -l) -gt 0 ]]; then
        
        # ========================================================================
        # Generate Unique Stash Name
        # ========================================================================
        
        # Create timestamp-based name for easy identification
        # Format: auto-stash-20250104_083015 (YYYYMMDD_HHMMSS)
        local stash_name="auto-stash-$(date +%Y%m%d_%H%M%S)"
        
        # ========================================================================
        # Dry Run Mode Support
        # ========================================================================
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log DRY "Would stash changes as: $stash_name"
            echo "$stash_name"  # Output name for caller
            return 0
        fi
        
        # ========================================================================
        # Create the Stash
        # ========================================================================
        
        # Use 'git stash push' (modern syntax) with descriptive message
        # --include-untracked ensures new files are also preserved
        if git stash push -m "$stash_name" --include-untracked > /dev/null 2>&1; then
            log INFO "  Stashed changes as: $stash_name"
            echo "$stash_name"  # Return stash name to caller
            return 0
        else
            # Stash creation failed - this is a serious error
            log ERROR "  Failed to stash changes"
            log ERROR "  Manual intervention may be required"
            return 1
        fi
    fi
    
    # ============================================================================
    # No Changes to Stash
    # ============================================================================
    
    # Repository is clean - no stashing needed
    log DEBUG "No uncommitted changes found - skipping stash creation"
    return 0  # Success, but no stash created
}

# Safely restore stashed changes
safe_stash_pop() {
    local stash_name="$1"
    if [[ -n "$stash_name" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log DRY "Would restore stashed changes: $stash_name"
            return 0
        fi
        
        if git stash list | grep -q "$stash_name"; then
            if git stash pop > /dev/null 2>&1; then
                log INFO "  Restored stashed changes: $stash_name"
            else
                log WARN "  Could not auto-restore stash: $stash_name (may have conflicts)"
                log WARN "  Manual restore: git stash apply stash@{0}"
                log WARN "  After resolving conflicts: git stash drop stash@{0}"
            fi
        fi
    fi
}

# Validate command string for basic safety
validate_command() {
    local cmd="$1"
    
    # Check for potentially dangerous patterns
    if [[ "$cmd" =~ \$\(|\`|eval|exec|source|sudo|su|rm\s+-rf|rm\s+/|mkfs|dd\s+if= ]]; then
        log ERROR "  Command contains potentially dangerous patterns: $cmd"
        return 1
    fi
    
    # Check for shell operators that require bash -c (not supported by array execution)
    if [[ "$cmd" =~ &&|\|\||;|\||>|< ]]; then
        log WARN "  Command contains shell operators and requires bash -c execution: $cmd"
        return 2  # Special return code for shell operators
    fi
    
    # Check for excessive complexity that might indicate injection attempts
    local special_count=$(echo "$cmd" | grep -o '[;&|><$`]' | wc -l)
    if [[ $special_count -gt 5 ]]; then
        log ERROR "  Command is too complex for safe execution: $cmd"
        return 1
    fi
    
    return 0  # Command appears safe for array execution
}

# Execute repository-specific commands
run_repo_commands() {
    local repo_name="$1"
    
    # Check for custom commands defined in env file using the scalable format
    if [[ -n "${REPO_COMMANDS:-}" ]]; then
        # Split REPO_COMMANDS into individual repository entries
        IFS=';' read -ra repo_entries <<< "$REPO_COMMANDS"
        for entry in "${repo_entries[@]}"; do
            IFS=':' read -ra repo_cmd <<< "$entry"
            if [[ "${repo_cmd[0]}" == "$repo_name" && -n "${repo_cmd[1]}" ]]; then
                log INFO "  Running custom commands for $repo_name from env file..."
                
                # Validate command for basic safety
                validate_command "${repo_cmd[1]}"
                local validation_result=$?
                
                if [[ $validation_result -eq 1 ]]; then
                    log ERROR "  Potentially unsafe command detected for $repo_name: ${repo_cmd[1]}"
                    log ERROR "  Skipping custom commands for security reasons"
                    return 1
                fi
                
                if [[ "$DRY_RUN" == "true" ]]; then
                    log DRY "Would run: ${repo_cmd[1]}"
                else
                    log DEBUG "  Running: ${repo_cmd[1]}"
                    
                    if [[ $validation_result -eq 2 ]]; then
                        # Command contains shell operators, use bash -c with additional safety
                        log WARN "  Using shell execution for complex command (extra caution advised)"
                        if ! timeout 300 env -i PATH="$PATH" HOME="$HOME" PWD="$(pwd)" bash -c "${repo_cmd[1]}" > /dev/null 2>&1; then
                            log WARN "  Custom commands failed for $repo_name, continuing anyway"
                        fi
                    else
                        # Simple command, use safer array execution
                        read -a cmd_array <<< "${repo_cmd[1]}"
                        if ! timeout 300 env -i PATH="$PATH" HOME="$HOME" PWD="$(pwd)" "${cmd_array[@]}" > /dev/null 2>&1; then
                            log WARN "  Custom commands failed for $repo_name, continuing anyway"
                        fi
                    fi
                fi
                return 0
            fi
        done
    fi
    
    # Fallback to hardcoded logic if no env variable is set or no matching repo found
    case "$repo_name" in
        "upstart_web")
            log INFO "  Running Rails-specific commands..."
            if command -v bundle > /dev/null 2>&1; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    log DRY "Would run: bundle install"
                else
                    log DEBUG "  Running bundle install..."
                    if ! bundle install > /dev/null 2>&1; then
                        log WARN "  Bundle install failed, continuing anyway"
                    fi
                fi
            else
                log WARN "  Bundle command not found, skipping bundle install"
            fi
            
            if command -v rails > /dev/null 2>&1; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    log DRY "Would run: rails db:migrate"
                else
                    log DEBUG "  Running rails db:migrate..."
                    if ! rails db:migrate > /dev/null 2>&1; then
                        log WARN "  Rails migration failed, continuing anyway"
                    fi
                fi
            else
                log WARN "  Rails command not found, skipping db:migrate"
            fi
            ;;
        *)
            log DEBUG "  No specific commands for repository: $repo_name"
            ;;
    esac
}

# Process a single repository
# This function performs the complete git sync workflow for one repository
# in sequential mode. It follows the same workflow as the parallel version
# but runs synchronously with detailed progress reporting.
#
# Parameters:
#   $1: repo_dir - Full path to repository directory
#
# Returns:
#   0 on success, 1 on failure
#
# Workflow:
#   1. Validate repository and get current state
#   2. Safely preserve local changes (stash if needed)
#   3. Switch to default branch and pull latest changes
#   4. Run repository-specific commands (e.g., bundle install)
#   5. Restore original branch and local changes
#   6. Report success/failure status
process_repo() {
    local repo_dir="$1"
    local repo_name=$(basename "$repo_dir")
    
    log INFO "Processing repository: $repo_name"
    
    # ============================================================================
    # STEP 1: Repository Validation and Initial State
    # ============================================================================
    
    # Change to repository directory - critical step that must succeed
    cd "$repo_dir" || {
        log ERROR "Cannot enter directory: $repo_dir"
        return 1
    }
    
    # Verify this is actually a git repository before attempting git operations
    # Prevents errors if directory exists but isn't version controlled
    if ! is_git_repo; then
        log WARN "  Not a git repository, skipping"
        return 0
    fi
    
    # Get current branch name to restore later
    # Skip repositories in detached HEAD state to avoid complications
    local current_branch
    if ! current_branch=$(git symbolic-ref --short HEAD 2>/dev/null); then
        log WARN "  In detached HEAD state, skipping"
        return 0
    fi
    
    log INFO "  Current branch: $current_branch"
    
    # ============================================================================
    # STEP 2: Local Changes Protection
    # ============================================================================
    
    # Check for any local modifications that need preservation
    # This includes uncommitted changes, staged files, and unpushed commits
    local stash_name=""
    if has_local_changes; then
        log INFO "  Found local changes (uncommitted or unpushed)"
        
        # Only stash uncommitted changes (staged + unstaged files)
        # Unpushed commits are preserved by staying on the current branch
        if [[ $(git status --porcelain | wc -l) -gt 0 ]]; then
            # Create a timestamped stash to safely preserve work
            if stash_name=$(safe_stash); then
                log DEBUG "  Uncommitted changes stashed successfully"
            else
                # If stashing fails, abort to prevent data loss
                log ERROR "  Failed to stash changes, skipping repository"
                return 1
            fi
        fi
    else
        log INFO "  No local changes detected"
    fi
    
    # ============================================================================
    # STEP 3: Default Branch Operations (Sync with Remote)
    # ============================================================================
    
    # Attempt to identify and switch to the repository's default branch
    # This is where we'll pull the latest changes from remote
    local default_branch
    if default_branch=$(get_default_branch); then
        log INFO "  Default branch: $default_branch"
        
        # Switch to default branch if we're not already on it
        # This allows us to pull the latest changes safely
        if [[ "$current_branch" != "$default_branch" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log DRY "Would checkout: $default_branch"
            else
                if git checkout "$default_branch" > /dev/null 2>&1; then
                    log INFO "  Switched to $default_branch"
                else
                    # If checkout fails, restore stash and abort
                    log ERROR "  Failed to checkout $default_branch"
                    safe_stash_pop "$stash_name"
                    return 1
                fi
            fi
        fi
        
        # Pull latest changes from remote origin
        # This updates the default branch with upstream changes
        if check_remote origin; then
            log INFO "  Pulling latest changes from origin..."
            if [[ "$DRY_RUN" == "true" ]]; then
                log DRY "Would run: git pull"
            else
                # Capture pull output for detailed reporting
                local pull_output
                if pull_output=$(git pull 2>&1); then
                    if echo "$pull_output" | grep -q "Already up to date"; then
                        log INFO "  Already up to date"
                    else
                        log INFO "  Pull completed successfully"
                        log DEBUG "  $pull_output"
                    fi
                else
                    # Pull failed - log but continue (network issues are common)
                    log WARN "  Pull failed: $pull_output"
                    log WARN "  Continuing with local repository state"
                fi
            fi
        else
            # No accessible remote - skip pulling (offline development scenario)
            log WARN "  No accessible remote origin, skipping pull"
        fi
    else
        # No identifiable default branch - stay on current branch
        log INFO "  No identifiable default branch, staying on $current_branch"
    fi
    
    # ============================================================================
    # STEP 4: Repository-Specific Maintenance Commands
    # ============================================================================
    
    # Execute custom commands based on repository type
    # Examples: bundle install, npm install, database migrations, etc.
    run_repo_commands "$repo_name"
    
    # ============================================================================
    # STEP 5: Restore Original Working State
    # ============================================================================
    
    # Switch back to the original branch if we changed it
    # This ensures the user's working environment is preserved
    if [[ -n "${default_branch:-}" ]] && [[ "$current_branch" != "$default_branch" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log DRY "Would checkout: $current_branch"
        else
            if git checkout "$current_branch" > /dev/null 2>&1; then
                log INFO "  Switched back to $current_branch"
            else
                # Checkout failure is serious but not fatal - user can fix manually
                log WARN "  Could not switch back to $current_branch"
                log WARN "  You may need to manually checkout: git checkout $current_branch"
            fi
        fi
    fi
    
    # Restore any stashed changes to preserve user's work-in-progress
    if [[ -n "$stash_name" ]]; then
        safe_stash_pop "$stash_name"
    fi
    
    # ============================================================================
    # STEP 6: Success Reporting
    # ============================================================================
    
    log INFO "  Repository $repo_name processed successfully"
    return 0
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
  
Environment Variables:
  CODE_DIR        Directory containing git repositories (default: ~/code)
  VERBOSE         Enable verbose logging (true/false)
  DRY_RUN         Enable dry-run mode (true/false)
  SKIP_DIRS       Space-separated list of directories to skip
  DEFAULT_BRANCHES Space-separated list of default branch names to check

Examples:
  $0                          # Update all repos in ~/code
  $0 --verbose                # Update with detailed logging
  $0 --dry-run                # Show what would be done
  CODE_DIR=/path/to/repos $0  # Use custom directory

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
            *)
                log ERROR "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Main execution
main() {
    parse_args "$@"
    
    log INFO "Starting git repository update script"
    log INFO "Working directory: $CODE_DIR"
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
    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
    fi
    
    # Count repositories
    local total_repos=0
    local processed_repos=0
    local failed_repos=0
    local skipped_repos=0
    
    # Process each directory
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
        
        # Skip repositories in excluded list
        for excluded_repo in $EXCLUDED_REPOS; do
            if [[ "$dir_name" == "$excluded_repo" ]]; then
                log INFO "Skipping excluded repository: $dir_name"
                skipped_repos=$((skipped_repos + 1))
                skip=true
                break
            fi
        done
        
        if [[ "$skip" == "true" ]]; then
            continue
        fi
        
        total_repos=$((total_repos + 1))
        
        echo "$(printf '%.0s-' {1..80})"
        
        if process_repo "$dir"; then
            processed_repos=$((processed_repos + 1))
        else
            failed_repos=$((failed_repos + 1))
            log ERROR "Failed to process repository: $dir_name"
        fi
        
        # Return to code directory
        cd "$CODE_DIR" || {
            log ERROR "Cannot return to code directory: $CODE_DIR"
            exit 1
        }
    done
    
    echo "$(printf '%.0s=' {1..80})"
    log INFO "Git repository sync completed"
    log INFO "Directories found: $((total_repos + skipped_repos))"
    log INFO "Repositories processed: $total_repos"
    log INFO "Successfully updated: $processed_repos"
    log INFO "Failed to update: $failed_repos"
    log INFO "Skipped directories: $skipped_repos"
    
    if [[ $failed_repos -gt 0 ]]; then
        log WARN "Some repositories failed to update. Check the log for details."
        exit 1
    fi
    
    log INFO "All repositories updated successfully!"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi