#!/opt/homebrew/bin/bash

# Wrapper script to install cron jobs for automated git sync
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure the main script is executable
chmod +x "$SCRIPT_DIR/scheduled_git_update.sh"

# Run the install-cron command
exec "$SCRIPT_DIR/scheduled_git_update.sh" install-cron
