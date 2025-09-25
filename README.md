# Git Repository Sync Automation

A comprehensive set of scripts to automatically sync all your local git repositories with their remote origins. Features intelligent fallback scheduling, macOS LaunchAgent integration, and complete safety for your local changes.

## 🚀 Quick Start

```bash
# Clone or download this repository (replace <your-repo-url> with the actual URL of this repository)
git clone <your-repo-url> automated-git-sync
cd automated-git-sync

# Create your personal configuration file from the example
cp .env.example .env
# Edit .env to customize settings (required)
nano .env

# Set up SSH for automation (ensures background processes can authenticate)
./setup_ssh_for_automation.sh

# Test the scripts work
./update_local_repos.sh --dry-run

# Set up automated daily updates (uses macOS LaunchAgent)
./switch_to_launchd.sh
```

## 📁 What's Included

- **`update_local_repos.sh`** - Enhanced sequential update script
- **`scheduled_git_update.sh`** - Scheduling wrapper with fallback logic
- **`.env.example`** - Example configuration file for customization

## 🛠 Script Overview

### 1. Sequential Script (`update_local_repos.sh`)
Safe, reliable updates one repository at a time.

```bash
./update_local_repos.sh [OPTIONS]

Options:
  -h, --help      Show help message
  -v, --verbose   Enable detailed logging
  -n, --dry-run   Preview changes without making them
  -d, --dir DIR   Set code directory (default: ~/code)
```

### 2. Scheduled Script (`scheduled_git_update.sh`)
Automation wrapper with intelligent scheduling and fallback logic.

```bash
./scheduled_git_update.sh [COMMAND]

Commands:
  scheduled         Run the scheduled update (primary run)
  fallback          Run the fallback update (only if primary run failed)
  status            Show status of recent runs and scheduled jobs
  clean-logs [DAYS] Clean up log files older than DAYS (default: 7, set to 0 to disable)
  help              Show help message
```

### 3. Setup Scripts
Helper scripts for initial configuration:

```bash
# Set up SSH configuration for automation
./setup_ssh_for_automation.sh

# Switch from cron to launchd (better for macOS)
./switch_to_launchd.sh

# Create launchd jobs manually
./create_launchd_job.sh
```

## ⚙️ Installation & Setup

### 1. Prerequisites
- macOS or Linux with Bash
- Git repositories using SSH authentication
- SSH key without passphrase (for automation) OR working SSH agent

### 2. Directory Setup
Place this repository in your main code directory:

```bash
cd ~/code
git clone <your-repo-url> automated-git-sync
```

### 3. Configuration
Create and customize your personal configuration file. Cron schedules must be defined in the `.env` file for the setup to work.

```bash
# Copy the example to create your configuration file
cp .env.example .env

# Edit your .env file to customize settings
nano .env
```

The `.env` file allows you to customize:
- `CODE_DIR`: Directory containing your git repositories (required).
- `PRIMARY_CRON_SCHEDULE`: Cron schedule for primary update run (required).
- `FALLBACK_CRON_SCHEDULE`: Cron schedule for fallback update run (required).
- `LOG_RETENTION_DAYS`: Number of days to keep logs, set to 0 to disable cleanup (required).
- `SKIP_DIRS`: Directories to skip during updates.
- `EXCLUDED_REPOS`: Specific repositories to exclude from updates.
- `DEFAULT_BRANCHES`: Default branch names to check.
- `VERBOSE` and `DRY_RUN`: Flags for logging and testing modes.
- `REPO_COMMANDS`: Custom commands for specific repositories.

### 4. Test the Scripts
Always test before automating:

```bash
# Test sequential script
./automated-git-sync/update_local_repos.sh --dry-run --verbose
```

### 5. Install Automated Scheduling
Set up automated updates using macOS LaunchAgent (better than cron):

```bash
# One-time setup: Configure SSH for automation
./automated-git-sync/setup_ssh_for_automation.sh

# Install LaunchAgent jobs based on schedules defined in .env
./automated-git-sync/switch_to_launchd.sh
```

## 🔧 Configuration Details

All configurations are managed through the `.env` file. Here's how to define custom commands for repositories and cron schedules:

```bash
# In your .env file
# Format for custom commands: REPO_COMMANDS='repo_name1:command1 && command2;repo_name2:command3 && command4'
REPO_COMMANDS='upstart_web:bundle install && bundle exec rails db:migrate'

# Exclude specific repositories from updates
EXCLUDED_REPOS="repo1 repo2"

# Define schedules (required) - uses cron format for compatibility
PRIMARY_CRON_SCHEDULE="15 9 * * 1-5"  # Primary schedule (weekdays at 9:15 AM)
FALLBACK_CRON_SCHEDULE="30 9 * * 1-5" # Fallback schedule (weekdays at 9:30 AM)
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
**Script logs** are stored in `automated-git-sync/logs/`:
- `git_update_YYYYMMDD_HHMMSS.log` - Individual run logs
- `scheduled_updates.log` - Scheduling activity log
- `git_update_status.json` - Latest run status (JSON format)
- `git_update.lock` - Lock file (active runs only)

**LaunchAgent logs** are stored in `~/Library/Logs/`:
- `git-update-scheduled.log` - Primary job output
- `git-update-fallback.log` - Fallback job output
- `git-update-scheduled-error.log` - Primary job errors
- `git-update-fallback-error.log` - Fallback job errors

### Viewing Logs
```bash
# Latest scheduled activity
tail -f automated-git-sync/logs/scheduled_updates.log

# Latest full run log
ls -t automated-git-sync/logs/git_update_*.log | head -1 | xargs cat

# LaunchAgent job logs
tail -f ~/Library/Logs/git-update-scheduled.log

# Status in readable format (requires jq)
jq '.' automated-git-sync/logs/git_update_status.json
```

## 🚨 Troubleshooting

### Common Issues

**Script not executable:**
```bash
chmod +x automated-git-sync/*.sh
```

**LaunchAgent jobs not running:**
```bash
# Check if jobs are loaded
launchctl list | grep git-update

# Check job status and logs
./scheduled_git_update.sh status
tail -f ~/Library/Logs/git-update-scheduled.log

# Manually trigger a job for testing
launchctl start com.user.git-update-scheduled
```

**Repository authentication issues:**
```bash
# Test SSH keys
ssh -T git@github.com

# Re-run SSH setup for automation
./setup_ssh_for_automation.sh

# Check SSH agent debug log
tail -f ~/.ssh/cron_ssh_debug.log

# For HTTPS authentication, use personal access tokens
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
VERBOSE=true ./update_local_repos.sh
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

## 🔄 Scheduling Details

### LaunchAgent Schedule
The automated scheduling uses macOS LaunchAgent with two jobs defined in your `.env` file:

```bash
# Primary run: Based on PRIMARY_CRON_SCHEDULE (converted to LaunchAgent format)
# Fallback run: Based on FALLBACK_CRON_SCHEDULE (converted to LaunchAgent format)
```

**Benefits of LaunchAgent over Cron:**
- Better SSH authentication support
- Improved macOS integration
- More reliable user environment
- Better logging and error handling

### Fallback Logic
The fallback run checks if the primary run was successful:
- ✅ **Primary succeeded** → Fallback skips (no duplicate work)
- ❌ **Primary failed** → Fallback runs (ensures daily sync)
- ⏰ **Primary didn't run** → Fallback runs (system was off/asleep)

### Notifications
On macOS, the script sends system notifications:
- ✅ Success: "Git repositories updated successfully"
- ❌ Failure: "Git update failed: [reason]"

## 📱 Usage Examples

### Manual Operations
```bash
# Conservative sync with detailed output
./update_local_repos.sh --verbose

# Preview what would happen
./update_local_repos.sh --dry-run

# Custom directory
CODE_DIR=/path/to/repos ./update_local_repos.sh

# Test specific settings
SKIP_DIRS="logs private" ./update_local_repos.sh --verbose
```

### Automation Management
```bash
# Set up automation (LaunchAgent)
./switch_to_launchd.sh

# Check automation status
./scheduled_git_update.sh status
launchctl list | grep git-update

# Remove automation
launchctl unload ~/Library/LaunchAgents/com.user.git-update-*.plist

# Manually trigger jobs
launchctl start com.user.git-update-scheduled
launchctl start com.user.git-update-fallback

# Clean old logs manually with custom retention
./scheduled_git_update.sh clean-logs 14
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
- **Customize freely**: Add your own repository-specific commands in `.env`

**Happy automated syncing! 🚀**
