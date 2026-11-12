#!/bin/zsh
# Installs (or updates) the Monday/Thursday sync-and-deploy schedule for this Mac.
# The script is copied out of the repo so a rebase can't change it while it runs.
set -euo pipefail
here=${0:A:h}
state="$HOME/Library/Application Support/casts-ai-sync"
plist="$HOME/Library/LaunchAgents/com.donovanmontoya.casts-ai-sync.plist"
mkdir -p "$state"
cp "$here/sync-and-deploy.sh" "$state/sync-and-deploy.sh"
cp "$here/../../podcasts/Credentials/LocalApiCredentials.swift" "$state/" 2>/dev/null || echo "No LocalApiCredentials.swift; the job will generate an empty one."
sed "s|__SCRIPT__|$state/sync-and-deploy.sh|" "$here/com.donovanmontoya.casts-ai-sync.plist" >"$plist"
launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Scheduled. Log: $state/sync.log. Run now: launchctl kickstart gui/$(id -u)/com.donovanmontoya.casts-ai-sync"
