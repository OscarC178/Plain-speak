#!/usr/bin/env bash
# Start Plainspeak at login and keep it running: launchd restarts it if it exits.
# Output goes to $PLAINSPEAK_HOME/launchd.log (times and errors only, never captures).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
BUN="$(command -v bun)" || { echo 'Bun is not installed.' >&2; exit 1; }
PLIST="$HOME/Library/LaunchAgents/com.oscarc.plainspeak.plist"
mkdir -p "$HOME/Library/LaunchAgents"
PLAINSPEAK_HOME="${PLAINSPEAK_HOME:-$HOME/.plainspeak}"
python3 - "$ROOT" "$PLIST" "$PLAINSPEAK_HOME" "$BUN" <<'PY'
import pathlib, plistlib, sys
root, target, home, bun = sys.argv[1:]
payload = {
    'Label': 'com.oscarc.plainspeak',
    'ProgramArguments': [bun, 'run', root + '/src/main.ts'],
    'WorkingDirectory': root,
    'EnvironmentVariables': {'PLAINSPEAK_HOME': home},
    'RunAtLoad': True,
    'KeepAlive': True,          # restart after a crash or a lost login
    'ThrottleInterval': 30,     # but never more often than every 30 seconds
    'StandardOutPath': home + '/launchd.log',
    'StandardErrorPath': home + '/launchd.log',
}
pathlib.Path(home).mkdir(mode=0o700, exist_ok=True)
pathlib.Path(target).write_bytes(plistlib.dumps(payload))
PY
plutil -lint "$PLIST"
# Reinstalling replaces a running copy instead of failing with "already loaded".
launchctl bootout "gui/$(id -u)/com.oscarc.plainspeak" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Plainspeak now starts at login and restarts if it stops. Log: $PLAINSPEAK_HOME/launchd.log"
