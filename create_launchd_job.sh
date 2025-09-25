#!/bin/bash

# Create launchd job for git repository updates
# This is more reliable than cron on macOS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.env"

# Source configuration for schedule
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Check required variables
if [[ -z "$PRIMARY_CRON_SCHEDULE" || -z "$FALLBACK_CRON_SCHEDULE" ]]; then
    echo "ERROR: PRIMARY_CRON_SCHEDULE and FALLBACK_CRON_SCHEDULE must be defined in .env"
    exit 1
fi

# Function to convert cron schedule to launchd format
cron_to_launchd() {
    local cron_schedule="$1"
    local job_type="$2"
    
    # Parse cron format: MIN HOUR DAY MONTH WEEKDAY
    read -r minute hour day month weekday <<< "$cron_schedule"
    
    # Remove leading zeros to avoid LaunchAgent integer parsing issues
    minute=$((10#$minute))
    hour=$((10#$hour))
    
    cat << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.git-update-${job_type}</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_DIR/scheduled_git_update.sh</string>
        <string>${job_type}</string>
    </array>
    
    <key>StartCalendarInterval</key>
    <dict>
        <key>Minute</key>
        <integer>$minute</integer>
        <key>Hour</key>
        <integer>$hour</integer>
EOF

    # Add weekday if specified (1-5 = Mon-Fri in cron, 1-7 = Sun-Sat in launchd)
    if [[ "$weekday" != "*" ]]; then
        if [[ "$weekday" == "1-5" ]]; then
            # Monday to Friday
            cat << EOF
        <key>Weekday</key>
        <array>
            <integer>2</integer>
            <integer>3</integer>
            <integer>4</integer>
            <integer>5</integer>
            <integer>6</integer>
        </array>
EOF
        fi
    fi

    cat << EOF
    </dict>
    
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/git-update-${job_type}.log</string>
    
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/git-update-${job_type}-error.log</string>
    
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
</dict>
</plist>
EOF
}

# Create LaunchAgents directory if it doesn't exist
mkdir -p "$HOME/Library/LaunchAgents"

# Generate primary job
echo "Creating primary scheduled job..."
cron_to_launchd "$PRIMARY_CRON_SCHEDULE" "scheduled" > "$HOME/Library/LaunchAgents/com.user.git-update-scheduled.plist"

# Generate fallback job  
echo "Creating fallback job..."
cron_to_launchd "$FALLBACK_CRON_SCHEDULE" "fallback" > "$HOME/Library/LaunchAgents/com.user.git-update-fallback.plist"

# Load the jobs
echo "Loading launchd jobs..."
launchctl load "$HOME/Library/LaunchAgents/com.user.git-update-scheduled.plist"
launchctl load "$HOME/Library/LaunchAgents/com.user.git-update-fallback.plist"

echo "✅ LaunchAgent jobs created and loaded successfully!"
echo ""
echo "To view job status:"
echo "  launchctl list | grep git-update"
echo ""
echo "To unload jobs:"
echo "  launchctl unload ~/Library/LaunchAgents/com.user.git-update-*.plist"
echo ""
echo "Logs will be written to:"
echo "  $HOME/Library/Logs/git-update-scheduled.log"
echo "  $HOME/Library/Logs/git-update-fallback.log"
