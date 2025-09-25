#!/bin/bash

# Wrapper script to run git updates with proper SSH environment
# This ensures SSH agent is available when running from cron

# Set up a minimal PATH for cron
export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$PATH"

# Debug logging for cron troubleshooting
exec 2>> "$HOME/.ssh/cron_ssh_debug.log"
echo "$(date): Cron wrapper starting, current SSH_AUTH_SOCK: ${SSH_AUTH_SOCK:-<unset>}" >&2

# Store username for better readability and error handling
USER_NAME=$(whoami)

# Function to test SSH agent
test_ssh_agent() {
    local sock="$1"
    if [ -n "$sock" ] && [ -S "$sock" ]; then
        SSH_AUTH_SOCK="$sock" ssh-add -l > /dev/null 2>&1
        return $?
    fi
    return 1
}

# Function to find working SSH agent
find_ssh_agent() {
    echo "$(date): Searching for SSH agent..." >&2
    
    # Method 1: Try saved environment
    if [ -f "$HOME/.ssh/agent_env" ]; then
        echo "$(date): Trying saved environment..." >&2
        source "$HOME/.ssh/agent_env" > /dev/null 2>&1
        if test_ssh_agent "$SSH_AUTH_SOCK"; then
            echo "$(date): Saved environment works!" >&2
            return 0
        fi
    fi
    
    # Method 2: Find macOS launchd SSH agent
    echo "$(date): Searching for macOS SSH agent..." >&2
    for sock in $(find /private/tmp -path "*/com.apple.launchd.*/Listeners" -user "$USER_NAME" 2>/dev/null); do
        echo "$(date): Testing socket: $sock" >&2
        if test_ssh_agent "$sock"; then
            export SSH_AUTH_SOCK="$sock"
            export SSH_AGENT_PID=""
            echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" > "$HOME/.ssh/agent_env"
            echo "SSH_AGENT_PID=" >> "$HOME/.ssh/agent_env"
            echo "$(date): Found working macOS SSH agent: $sock" >&2
            return 0
        fi
    done
    
    # Method 3: Traditional SSH agent
    echo "$(date): Searching for traditional SSH agent..." >&2
    local ssh_pid=$(pgrep -u "$USER_NAME" ssh-agent | head -1)
    if [ -n "$ssh_pid" ]; then
        for sock in $(find /tmp -name "agent.*" -user "$USER_NAME" 2>/dev/null); do
            echo "$(date): Testing traditional socket: $sock" >&2
            if test_ssh_agent "$sock"; then
                export SSH_AUTH_SOCK="$sock"
                export SSH_AGENT_PID="$ssh_pid"
                echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" > "$HOME/.ssh/agent_env"
                echo "SSH_AGENT_PID=$SSH_AGENT_PID" >> "$HOME/.ssh/agent_env"
                echo "$(date): Found working traditional SSH agent: $sock" >&2
                return 0
            fi
        done
    fi
    
    echo "$(date): No working SSH agent found!" >&2
    return 1
}

# Try to set up SSH agent
if ! test_ssh_agent "$SSH_AUTH_SOCK"; then
    echo "$(date): Current SSH agent not working, searching for alternatives..." >&2
    if ! find_ssh_agent; then
        echo "$(date): ERROR: No working SSH agent found. Git operations may fail." >&2
        # Continue anyway - the script will handle SSH failures gracefully
    fi
else
    echo "$(date): Current SSH agent is working" >&2
fi

# Final SSH agent status
echo "$(date): Final SSH_AUTH_SOCK: ${SSH_AUTH_SOCK:-<unset>}" >&2
if [ -n "$SSH_AUTH_SOCK" ]; then
    SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh-add -l >&2 2>&1 || echo "$(date): SSH agent test failed" >&2
fi

# Determine the script directory dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set environment to use regular script by default (more reliable than parallel for cron)
export UPDATE_SCRIPT="${UPDATE_SCRIPT:-$SCRIPT_DIR/update_local_repos.sh}"

# Run the scheduled update
exec "$SCRIPT_DIR/scheduled_git_update.sh" "$@"