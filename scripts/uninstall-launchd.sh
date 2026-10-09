#!/usr/bin/env bash
set -euo pipefail
launchctl bootout "gui/$(id -u)/com.oscarc.plainspeak"
echo 'Plainspeak stopped and will no longer start at login. The plist remains in ~/Library/LaunchAgents.'
