#!/usr/bin/env bash
# Slipway "Dev Start Command" wrapper for the Plainspeak daemon:
#   bash daemon/slipway-run.sh
#
# Slipway's Run panel has no TTY (stdin is ignored, output is piped), so the
# interactive Claude session cannot run in the tab directly. This script:
#   1. installs dependencies if this checkout has none (fresh branch/worktree),
#   2. starts the tmux session via start.sh (idempotent),
#   3. answers the --dangerously-load-development-channels warning with Enter,
#   4. waits for you if Claude asks whether to trust a new checkout (never auto-trusts),
#   5. prints a health line every 60 seconds while the session lives.
# Stopping the Run tab sends SIGTERM here, which stops the daemon as well.
# Exits non-zero if the Claude session dies, so the tab shows the failure.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
HEALTH='http://127.0.0.1:8790/health'

healthy() { curl -sf -m 2 "$HEALTH" >/dev/null; }
alive() { tmux has-session -t '=plainspeak' 2>/dev/null; }
pane() { tmux capture-pane -pt plainspeak 2>/dev/null; }
stop() { echo 'Stopping Plainspeak daemon...'; bash "$ROOT/daemon/stop.sh"; exit 0; }
trap stop INT TERM

# A fresh branch or worktree has no node_modules yet.
if [[ ! -d "$ROOT/node_modules" ]]; then
  echo 'Installing dependencies (first run in this checkout)...'
  (cd "$ROOT" && bun install --frozen-lockfile) || exit 1
fi
bash "$ROOT/daemon/start.sh" || exit 1

accepted=false; told=false; waited=0
until healthy; do
  alive || { echo 'Claude session exited during startup. Run "bun run daemon:attach" to see why.' >&2; exit 1; }
  screen="$(pane)"
  if grep -q 'Yes, I trust this folder' <<<"$screen"; then
    # Workspace trust is a safety check, so a person answers it. No timeout while waiting.
    if [[ $told == false ]]; then
      echo 'First run in this checkout: Claude is asking whether to trust this folder.'
      echo 'Open a terminal tab here, run "bun run daemon:attach", choose "Yes, I trust this folder",'
      echo 'then detach with Control+B, D. This tab carries on by itself.'
      told=true
    fi
  elif [[ $accepted == false ]] && grep -q 'I am using this for local development' <<<"$screen"; then
    tmux send-keys -t plainspeak Enter
    accepted=true
    echo 'Accepted the development-channels warning.'
  else
    waited=$((waited + 1))
    if (( waited > 90 )); then
      echo 'Service did not come up on 127.0.0.1:8790 within 90s. The session shows:' >&2
      pane | sed '/^[[:space:]]*$/d' | tail -12 >&2
      exit 1
    fi
  fi
  sleep 1 & wait $!
done
echo 'Plainspeak ready at http://127.0.0.1:8790 - press a mouse side button or use the PS menu.'

# Keep the tab alive while the session lives. "sleep &" + wait lets the trap fire promptly.
while alive; do
  echo "$(date '+%H:%M:%S') $(curl -s -m 2 "$HEALTH" || echo 'service not responding')"
  sleep 60 & wait $!
done
echo 'Plainspeak session ended (quota wait, crash or manual exit). Start the tab again.' >&2
exit 1
