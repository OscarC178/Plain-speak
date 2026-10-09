#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if tmux has-session -t '=plainspeak' 2>/dev/null; then echo 'Session exists (may be waiting for consent or quota).'; else echo 'Session stopped.'; fi
curl --silent --show-error --max-time 3 http://127.0.0.1:8790/health || true
