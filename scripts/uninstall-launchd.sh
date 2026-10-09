#!/usr/bin/env bash
set -euo pipefail
launchctl bootout "gui/$(id -u)/com.oscarc.plainspeak"
echo 'Login startup disabled. The plist remains; the current tmux session is unchanged.'
