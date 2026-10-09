#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HOME/.hammerspoon"
# Refuse to overwrite existing unrelated modules.
if [[ -e "$HOME/.hammerspoon/plainspeak.lua" && ! -L "$HOME/.hammerspoon/plainspeak.lua" ]]; then echo 'Existing plainspeak.lua; move it yourself before installing.' >&2; exit 1; fi
ln -sfn "$ROOT/hammerspoon/plainspeak.lua" "$HOME/.hammerspoon/plainspeak.lua"
# The token is shared by every checkout; the daemon creates it on first start.
PLAINSPEAK_HOME="${PLAINSPEAK_HOME:-$HOME/.plainspeak}"
mkdir -p "$PLAINSPEAK_HOME"; chmod 700 "$PLAINSPEAK_HOME"
ln -sfn "$PLAINSPEAK_HOME/token" "$HOME/.hammerspoon/plainspeak-token"
python3 - "$HOME/.hammerspoon/init.lua" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text() if p.exists() else ''
line = 'require("plainspeak")'
if line not in s:
    p.write_text(s + '\n-- Plainspeak personal reading overlay\n' + line + '\n')
PY
echo 'Installed. Open Hammerspoon, grant Accessibility and Screen Recording, then quit and reopen Hammerspoon.'
