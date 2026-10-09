#!/usr/bin/env bash
# Run Plainspeak in the foreground: `bun run start` in a terminal, or `npm run dev`
# from Slipway's Run panel. Installs dependencies on the first run in a fresh
# checkout, then starts the local service with a warm Claude session.
# Control+C, or stopping the Slipway tab, ends it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$ROOT"
command -v bun >/dev/null || { echo 'Bun is not installed. See "What you need" in the README.' >&2; exit 1; }
# A new branch or worktree has no dependencies yet, or predates the Agent SDK.
if [[ ! -d node_modules/@anthropic-ai/claude-agent-sdk ]]; then
  echo 'Installing dependencies (first run in this checkout)...'
  bun install --frozen-lockfile
fi
exec bun run src/main.ts
