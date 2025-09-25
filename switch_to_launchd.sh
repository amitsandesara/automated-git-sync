#!/bin/bash

# Switch from cron to launchd for better macOS integration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔄 Switching from cron to launchd for Git repository updates..."
echo ""

# Step 1: Remove existing cron jobs
echo "1️⃣ Removing existing cron jobs..."
if "$SCRIPT_DIR/scheduled_git_update.sh" remove-cron; then
    echo "✅ Cron jobs removed successfully"
else
    echo "⚠️  Warning: Could not remove cron jobs (they may not exist)"
fi
echo ""

# Step 2: Create and load launchd jobs
echo "2️⃣ Creating launchd jobs..."
if "$SCRIPT_DIR/create_launchd_job.sh"; then
    echo "✅ LaunchAgent jobs created and loaded"
else
    echo "❌ Failed to create launchd jobs"
    exit 1
fi
echo ""

# Step 3: Test the setup
echo "3️⃣ Testing the setup..."
echo "Current launchd jobs:"
launchctl list | grep git-update || echo "No git-update jobs found"
echo ""

echo "🎉 Successfully switched to launchd!"
echo ""
echo "Benefits of launchd over cron:"
echo "  • Better integration with macOS services"
echo "  • Access to user's SSH keychain"
echo "  • More reliable environment variables"
echo "  • Better logging and error handling"
echo ""
echo "To manually run a job for testing:"
echo "  launchctl start com.user.git-update-scheduled"
echo ""
echo "To check logs:"
echo "  tail -f ~/Library/Logs/git-update-scheduled.log"
