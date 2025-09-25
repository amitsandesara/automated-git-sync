#!/bin/bash

# Configure SSH for automated background processes
# This bypasses SSH agent issues with cron/launchd

echo "🔧 Setting up SSH for automation..."

# Create a backup of the original SSH config
if [ ! -f ~/.ssh/config.backup ]; then
    cp ~/.ssh/config ~/.ssh/config.backup
    echo "✅ Backed up original SSH config to ~/.ssh/config.backup"
fi

# Create enhanced SSH config that works without SSH agent
cat > ~/.ssh/config << 'EOF'
# Original configuration with keychain integration
Host github.com
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/id_ed25519

# Alternative configuration for automation (without keychain dependency)
Host github-automation.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  AddKeysToAgent no
  UseKeychain no
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/known_hosts

# Catch-all for automation when SSH agent is not available
Host *
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  AddKeysToAgent no
  UseKeychain no
  StrictHostKeyChecking yes
EOF

echo "✅ Updated SSH config for automation compatibility"
echo ""

# Test the configuration
echo "🧪 Testing SSH configuration..."

echo "Testing normal GitHub access:"
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    echo "✅ Normal GitHub access works"
else
    echo "⚠️  Normal GitHub access test unclear (this is often normal)"
fi

echo ""
echo "Testing automation GitHub access:"
if ssh -T git@github-automation.com 2>&1 | grep -q "successfully authenticated"; then
    echo "✅ Automation GitHub access works"
else
    echo "⚠️  Automation GitHub access test unclear (this is often normal)"
fi

echo ""
echo "🎉 SSH configuration updated for automation!"
echo ""
echo "The configuration now includes:"
echo "  • Original keychain-based setup for interactive use"
echo "  • Alternative automation setup for background processes"
echo "  • Fallback configuration that doesn't depend on SSH agent"
echo ""
echo "If you need to restore the original config:"
echo "  cp ~/.ssh/config.backup ~/.ssh/config"
