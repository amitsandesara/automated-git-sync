#!/bin/bash

# Wrapper script to run git updates with proper SSH environment
# This ensures SSH agent is available when running from cron

# Source the SSH agent environment
if [ -f "$HOME/.ssh/agent_env" ]; then
    source "$HOME/.ssh/agent_env" > /dev/null 2>&1
fi

# If SSH agent isn't running, try to find it
if [ -z "$SSH_AUTH_SOCK" ] || ! ssh-add -l > /dev/null 2>&1; then
    # Store username for better readability and error handling
    USER_NAME=$(whoami)
    
    # Look for existing SSH agent
    SSH_AGENT_PID=$(pgrep -u "$USER_NAME" ssh-agent | head -1)
    if [ -n "$SSH_AGENT_PID" ]; then
        export SSH_AUTH_SOCK=$(find /tmp -name "agent.*" -user "$USER_NAME" 2>/dev/null | head -1)
        if [ -n "$SSH_AUTH_SOCK" ] && ssh-add -l > /dev/null 2>&1; then
            # Found working SSH agent
            echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" > "$HOME/.ssh/agent_env"
            echo "SSH_AGENT_PID=$SSH_AGENT_PID" >> "$HOME/.ssh/agent_env"
        fi
    fi
fi

# Determine the script directory dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set environment to use regular script by default (more reliable than parallel for cron)
export UPDATE_SCRIPT="${UPDATE_SCRIPT:-$SCRIPT_DIR/update_local_repos.sh}"

# Run the scheduled update
exec "$SCRIPT_DIR/scheduled_git_update.sh" "$@"