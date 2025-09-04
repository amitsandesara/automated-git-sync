# Git Repository Sync Automation

A comprehensive set of scripts to automatically sync all your local git repositories with their remote origins. Features parallel processing, intelligent fallback scheduling, and complete safety for your local changes.

## 🚀 Quick Start

```bash
# Clone or download this repository
git clone <your-repo-url> automated-git-sync
cd automated-git-sync

# Test the scripts work
./update_local_repos_parallel.sh --dry-run

# Set up automated daily updates
./scheduled_git_update.sh install-cron
```

## 📁 What's Included

- **`update_git.sh`** - Original simple script (kept for reference)
- **`update_local_repos.sh`** - Enhanced sequential update script
- **`update_local_repos_parallel.sh`** - High-performance parallel processing script
- **`scheduled_git_update.sh`** - Scheduling wrapper with fallback logic
- **`update_local_repos_plan.md`** - Development planning document

## 🛠 Script Overview

### 1. Sequential Script (`update_local_repos.sh`)
Safe, reliable updates one repository at a time.

```bash
./update_local_repos.sh [OPTIONS]

Options:
  -h, --help      Show help message
  -v, --verbose   Enable detailed loggings
  -n, --dry-run   Preview changes without making them
  -d, --dir DIR   Set code directory (default: ~/code)
```

### 2. Parallel Script (`update_local_repos_parallel.sh`)
High-performance updates with configurable parallel processing.

```bash
./update_local_repos_parallel.sh [OPTIONS]

Options:
  -h, --help        Show help message
  -v, --verbose     Enable detailed logging
  -n, --dry-run     Preview changes without making them
  -d, --dir DIR     Set code directory (default: ~/code)
  -b, --batch N     Set parallel jobs (default: 3)
  -t, --timeout N   Set job timeout in seconds (default: 300)
```

### 3. Scheduled Script (`scheduled_git_update.sh`)
Automation wrapper with intelligent scheduling and fallback logic.

```bash
./scheduled_git_update.sh [COMMAND]

Commands:
  scheduled       Run the scheduled update (8 AM run)
  fallback        Run the fallback update (9:30 AM run, only if needed)
  status          Show status of recent runs and cron jobs
  install-cron    Install cron jobs for automated scheduling
  remove-cron     Remove cron jobs
  test            Test run without scheduling
  help            Show help message
```

## ⚙️ Installation & Setup

### 1. Prerequisites
**Bash 4.0+ Required:** The parallel script uses associative arrays (Bash 4.0+ feature)
```bash
# macOS users: Update from default Bash 3.2
brew install bash
sudo cp /opt/homebrew/bin/bash /bin/bash
```

### 2. Directory Setup
Place this repository in your main code directory:
```bash
cd ~/code
git clone <your-repo-url> automated-git-sync
```

### 3. Test the Scripts
Always test before automating:
```bash
# Test parallel script (recommended)
./automated-git-sync/update_local_repos_parallel.sh --dry-run --verbose

# Test sequential script
./automated-git-sync/update_local_repos.sh --dry-run --verbose
```

### 4. Install Automated Scheduling
Set up daily automated updates:
```bash
./automated-git-sync/scheduled_git_update.sh install-cron
```

This creates:
- **8:00 AM** (Mon-Fri): Primary update run
- **9:30 AM** (Mon-Fri): Fallback run (only if 8 AM failed)

## 🔧 Configuration

### Environment Variables
```bash
# Directory containing git repositories
export CODE_DIR="$HOME/code"

# Enable verbose logging
export VERBOSE="true"

# Enable dry-run mode
export DRY_RUN="true"

# Parallel processing batch size
export BATCH_SIZE="5"

# Job timeout in seconds
export JOB_TIMEOUT="300"

# Directories to skip
export SKIP_DIRS="logs .DS_Store node_modules"

# Default branch names to check
export DEFAULT_BRANCHES="main master develop"
```

### Repository-Specific Commands
The scripts automatically run custom commands for specific repositories. Currently configured for:

**Rails Applications** (e.g., `upstart_web`):
- `bundle install` - Update gem dependencies
- `rails db:migrate` - Run database migrations

To add custom commands for other repositories, edit the `run_repo_commands()` function in the scripts:

```bash
case "$repo_name" in
    "my_node_app")
        npm install
        npm run build
        ;;
    "my_python_app")
        pip install -r requirements.txt
        python manage.py migrate
        ;;
esac
```

## 🔒 Safety Features

### Local Changes Protection
- **Automatic stashing** of uncommitted changes with timestamps
- **Safe restoration** with conflict detection
- **Unpushed commit detection** and preservation
- **Branch restoration** to original working branch

### Error Handling
- **Non-blocking failures** - one failed repo doesn't stop others
- **Timeout protection** - prevents hanging operations
- **Network resilience** - handles offline/unreachable remotes
- **Repository validation** - confirms git repos before processing

### Logging & Monitoring
- **Detailed logging** with timestamps and color coding
- **Status tracking** with JSON reports
- **Lock file protection** prevents concurrent runs
- **Progress reporting** with success/failure statistics

## 📊 Monitoring & Status

### Check Status
```bash
# View recent run history and cron status
./scheduled_git_update.sh status
```

### Log Files
All logs are stored in `automated-git-sync/logs/`:
- `git_update_YYYYMMDD_HHMMSS.log` - Individual run logs
- `scheduled_updates.log` - Scheduling activity log
- `git_update_status.json` - Latest run status (JSON format)
- `git_update.lock` - Lock file (active runs only)

### Viewing Logs
```bash
# Latest scheduled activity
tail -f automated-git-sync/logs/scheduled_updates.log

# Latest full run log
ls -t automated-git-sync/logs/git_update_*.log | head -1 | xargs cat

# Status in readable format (requires jq)
jq '.' automated-git-sync/logs/git_update_status.json
```

## 🚨 Troubleshooting

### Common Issues

**Bash version compatibility (macOS):**
The scripts require Bash 4.0+ for associative arrays. macOS ships with Bash 3.2 by default.

```bash
# Check your bash version
/bin/bash --version

# If you see version 3.2, install newer bash via Homebrew
brew install bash

# Update system bash (recommended approach)
sudo cp /opt/homebrew/bin/bash /bin/bash

# Verify the fix
/bin/bash --version  # Should show 5.x
```

**Associative array errors:**
If you see `declare: -A: invalid option`, you're using old Bash:
```bash
# Error indicates Bash < 4.0
./update_local_repos_parallel.sh: line 29: declare: -A: invalid option

# Fix by updating bash (see above) or run with explicit path
/opt/homebrew/bin/bash ./update_local_repos_parallel.sh
```

**Script not executable:**
```bash
chmod +x automated-git-sync/*.sh
```

**Cron jobs not running:**
```bash
# Check if cron is running
sudo launchctl list | grep cron

# Check cron logs
tail -f /var/log/system.log | grep cron
```

**Repository authentication issues:**
```bash
# Test SSH keys
ssh -T git@github.com

# Or use personal access tokens for HTTPS
git config --global credential.helper store
```

**Stash conflicts:**
If stash restoration fails, manually resolve:
```bash
cd problematic-repo
git stash list
git stash apply stash@{0}  # Resolve conflicts manually
git stash drop stash@{0}   # Clean up after resolving
```

### Debugging

**Enable verbose mode:**
```bash
VERBOSE=true ./update_local_repos_parallel.sh
```

**Test individual repository:**
```bash
cd ~/code/problematic-repo
git fetch origin
git status
git stash list
```

**Check network connectivity:**
```bash
git ls-remote --heads origin
```

**Parallel script appears to do nothing:**
The parallel script runs background jobs that complete quickly. This is normal:
```bash
# You'll see minimal output like this:
[MAIN] [INFO] Starting parallel git repository update script
[MAIN] [INFO] Working directory: /Users/you/code  
[MAIN] [INFO] Batch size: 3 parallel jobs
[MAIN] [INFO] Cleaning up parallel jobs...

# To see actual work being done:
./update_local_repos_parallel.sh --verbose

# Check the log file for details:
cat logs/git_update_*.log | tail -50

# Verify repositories were processed:
./update_local_repos_parallel.sh --dry-run --verbose | head -20
```

## 🔄 Scheduling Details

### Cron Schedule
The automated scheduling uses two cron entries:

```bash
# Primary run: 8:00 AM on weekdays (Mon-Fri)
0 8 * * 1-5 /Users/you/code/automated-git-sync/scheduled_git_update.sh scheduled

# Fallback run: 9:30 AM on weekdays (only if 8 AM failed)
30 9 * * 1-5 /Users/you/code/automated-git-sync/scheduled_git_update.sh fallback
```

### Fallback Logic
The 9:30 AM run checks if the 8 AM run was successful:
- ✅ **8 AM succeeded** → 9:30 AM skips (no duplicate work)
- ❌ **8 AM failed** → 9:30 AM runs (ensures daily sync)
- ⏰ **8 AM didn't run** → 9:30 AM runs (system was off/asleep)

### Notifications
On macOS, the script sends system notifications:
- ✅ Success: "Git repositories updated successfully"
- ❌ Failure: "Git update failed: [reason]"

## 📱 Usage Examples

### Manual Operations
```bash
# Quick sync with parallel processing
./update_local_repos_parallel.sh

# Conservative sync with detailed output
./update_local_repos.sh --verbose

# Preview what would happen
./update_local_repos_parallel.sh --dry-run

# Custom directory and batch size
CODE_DIR=/path/to/repos ./update_local_repos_parallel.sh --batch 5

# Test specific settings
SKIP_DIRS="logs private" ./update_local_repos.sh --verbose
```

### Automation Management
```bash
# Set up automation
./scheduled_git_update.sh install-cron

# Check automation status
./scheduled_git_update.sh status

# Test without scheduling
./scheduled_git_update.sh test

# Remove automation
./scheduled_git_update.sh remove-cron
```

### Integration Examples
```bash
# In CI/CD pipeline
if ./update_local_repos.sh --dry-run; then
    echo "All repos can be updated safely"
else
    echo "Some repos need attention"
fi

# With notification integration (Slack, etc.)
./scheduled_git_update.sh scheduled && curl -X POST -H 'Content-type: application/json' --data '{"text":"Git sync completed"}' YOUR_SLACK_WEBHOOK
```

## 🤝 Contributing

This is a personal automation tool, but improvements are welcome:

1. **Testing**: Always test changes with `--dry-run` first
2. **Logging**: Add appropriate logging for new features
3. **Safety**: Ensure changes preserve local work
4. **Documentation**: Update this README for new features

## 📝 License

MIT License - feel free to adapt for your own use.

---

## ⭐ Pro Tips

- **Start small**: Test with `--dry-run` and a few repositories first
- **Monitor initially**: Check logs daily for the first week after setup
- **Backup strategy**: This syncs with remotes but isn't a backup solution
- **Network awareness**: Scripts handle network issues gracefully but won't retry indefinitely
- **Customize freely**: Add your own repository-specific commands as needed

**Happy automated syncing! 🚀**