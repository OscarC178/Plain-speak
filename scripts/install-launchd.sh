#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HOME/Library/LaunchAgents"
PLAINSPEAK_HOME="${PLAINSPEAK_HOME:-$HOME/.plainspeak}"
python3 - "$ROOT" "$HOME/Library/LaunchAgents/com.oscarc.plainspeak.plist" "$PLAINSPEAK_HOME" <<'PY'
import pathlib, plistlib, sys
root, target, home = sys.argv[1:]
payload = {'Label': 'com.oscarc.plainspeak', 'ProgramArguments': ['/bin/bash', root+'/daemon/start.sh'], 'WorkingDirectory': root, 'RunAtLoad': True, 'StandardOutPath': home+'/launchd.log', 'StandardErrorPath': home+'/launchd.log'}
pathlib.Path(home).mkdir(mode=0o700, exist_ok=True)
pathlib.Path(target).write_bytes(plistlib.dumps(payload))
PY
plutil -lint "$HOME/Library/LaunchAgents/com.oscarc.plainspeak.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.oscarc.plainspeak.plist"
echo 'Login startup enabled. launchd starts tmux once; it does not supervise the Claude child.'
