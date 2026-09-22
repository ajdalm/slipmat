#!/bin/bash
# make-shortcuts.sh — generate + sign the four slipmat menu-bar Shortcuts.
# (the crop launcher mode still exists; an AUTO CROP shortcut may return later)
#
# A .shortcut file is a plist; Apple's `shortcuts sign` (macOS 12+) signs a
# generated one so the Shortcuts app will import it via `open` — one click on
# "Add Shortcut" per file, no manual building. The plists carry
# WFWorkflowTypes=[MenuBar], so each Shortcut arrives already pinned to the
# menu bar. The shortcut NAME comes from the FILE name.
#
# Each Shortcut is a one-line delegator to shortcuts/launch.applescript with
# this repo's absolute path baked in at generation time (edit-once rule: all
# behavior lives in the launcher, on disk).
#
# Usage: make-shortcuts.sh [output-dir]     (default ~/.slipmat/shortcuts)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/.slipmat/shortcuts}"
mkdir -p "$OUT"

fail=0
make_one() {  # $1 = shortcut name, $2 = mode, $3 = icon color int
  local plist="$OUT/.unsigned.$2.shortcut" signed="$OUT/$1.shortcut"
  REPO="$REPO" MODE="$2" COLOR="$3" python3 - "$plist" <<'PY' || return 1
import os, plistlib, shlex, sys
repo, mode = os.environ['REPO'], os.environ['MODE']
wf = {
 'WFWorkflowActions': [{
    'WFWorkflowActionIdentifier': 'is.workflow.actions.runshellscript',
    'WFWorkflowActionParameters': {
        'Script': 'osascript %s %s %s' % (
            shlex.quote(repo + '/shortcuts/launch.applescript'),
            shlex.quote(repo), mode),
        'Shell': '/bin/zsh',
        'InputMode': 'to stdin',
    }}],
 'WFWorkflowClientVersion': '1230.6',
 'WFWorkflowHasOutputFallback': False,
 'WFWorkflowHasShortcutInputVariables': False,
 'WFWorkflowIcon': {'WFWorkflowIconGlyphNumber': 59511,
                    'WFWorkflowIconStartColor': int(os.environ['COLOR'])},
 'WFWorkflowImportQuestions': [],
 'WFWorkflowInputContentItemClasses': [],
 'WFWorkflowMinimumClientVersion': 900,
 'WFWorkflowMinimumClientVersionString': '900',
 'WFWorkflowOutputContentItemClasses': [],
 'WFWorkflowTypes': ['MenuBar'],
}
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(wf, f)
PY
  # sign on THIS machine (needs an iCloud-signed-in Mac; harmless stderr noise
  # from the shortcuts binary is routine on some macOS builds). The signing
  # daemon is flaky under burst load — field-tested: retry up to 3 times.
  local try=1
  while :; do
    rm -f "$signed" 2>/dev/null
    shortcuts sign --mode anyone --input "$plist" --output "$signed" 2>/dev/null
    if [ -s "$signed" ]; then
      rm -f "$plist"
      printf '  ✓ %s\n' "$1"
      return 0
    fi
    [ "$try" -ge 3 ] && break
    try=$((try+1)); sleep 1
  done
  rm -f "$plist" "$signed" 2>/dev/null
  printf '  ✗ %s — signing failed\n' "$1"
  return 1
}

printf 'building Shortcuts for %s\n' "$REPO"
make_one "[SLIPMAT VIDEO] AUTO(BEST)"     best   4274264319 || fail=1
make_one "[SLIPMAT VIDEO] PICKER"         picker 4271458815 || fail=1
make_one "[SLIPMAT VIDEO] STUDIO"         studio 4274264319 || fail=1
make_one "[SLIPMAT AUDIO] AUTO(BEST)"     audio  463140863  || fail=1   # blue

if [ "$fail" = "1" ]; then
  cat <<EOF

Some Shortcuts could not be signed (signing needs a Mac signed into iCloud).
No problem — shortcuts/SETUP.md walks you through creating them by hand in
about two minutes; each is a single pasted line.
EOF
  exit 1
fi
printf 'signed files in: %s\nDouble-click each (or let slipmat hello open them) and click "Add Shortcut".\n' "$OUT"
