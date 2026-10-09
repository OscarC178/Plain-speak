#!/usr/bin/env bash
# `npm run dev`, which is what Slipway's "Start dev server" runs: build this checkout's
# Plainspeak.app, install it over /Applications/Plainspeak.app, open it, and follow its log.
# Stopping the tab quits the app. Only run branches you trust: the app gets your permissions.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/build-app.sh" --install || exit 1
quit() { osascript -e 'quit app "Plainspeak"' 2>/dev/null; echo 'Plainspeak quit.'; exit 0; }
trap quit INT TERM
echo 'Following ~/.plainspeak/app.log (times and errors only, never captures).'
tail -n 5 -F "$HOME/.plainspeak/app.log" &
wait $!
