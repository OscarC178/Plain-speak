#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if tmux has-session -t '=plainspeak' 2>/dev/null; then tmux kill-session -t '=plainspeak'; fi
echo 'Plainspeak stopped.'
