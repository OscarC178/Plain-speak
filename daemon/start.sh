#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
for tool in tmux claude bun; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
if tmux has-session -t '=plainspeak' 2>/dev/null; then echo 'Plainspeak session already exists.'; exit 0; fi
# Personal state (token, config, rules) lives outside the checkout; see src/paths.ts.
PLAINSPEAK_HOME="${PLAINSPEAK_HOME:-$HOME/.plainspeak}"
mkdir -p "$PLAINSPEAK_HOME"; chmod 700 "$PLAINSPEAK_HOME"
# Haiku 5.5 by default: fast and cheap for short rewrites. Override per run with
# PLAINSPEAK_MODEL / PLAINSPEAK_EFFORT (e.g. PLAINSPEAK_MODEL=opus PLAINSPEAK_EFFORT=high).
MODEL="${PLAINSPEAK_MODEL:-claude-haiku-5-5}"
EFFORT="${PLAINSPEAK_EFFORT:-medium}"
# Quote each word before handing the command to tmux's shell. No -p or API key.
printf -v invocation '%q ' claude --model "$MODEL" --effort "$EFFORT" --name plainspeak --permission-mode default --settings "$ROOT/daemon/claude-settings.json" --dangerously-load-development-channels server:plainspeak
printf -v home_env 'PLAINSPEAK_HOME=%q' "$PLAINSPEAK_HOME"
# Prevent inherited API credentials from selecting API billing instead of the user's login.
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY || true
tmux new-session -d -s plainspeak -c "$ROOT" -x 140 -y 45 "env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY $home_env $invocation"
echo "Plainspeak started ($MODEL, effort $EFFORT). Run bun run daemon:attach to complete first-run trust/channel prompts."
