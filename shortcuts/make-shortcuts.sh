#!/bin/bash
# make-shortcuts.sh — generate + sign the five slipmat menu-bar Shortcuts
# (six with -c: the optional AUTO CROP(PiP) door to the zoom-crop batch).
#
# A .shortcut file is a plist; Apple's `shortcuts sign` (macOS 12+) signs a
# generated one so the Shortcuts app will import it via `open` — one press of
# "Add Shortcut" per file (slipmat hello opens them in a chain), no manual building. The plists carry
# WFWorkflowTypes=[MenuBar], so each Shortcut arrives already pinned to the
# menu bar. The shortcut NAME comes from the FILE name.
#
# Each Shortcut is a one-line delegator to shortcuts/launch.applescript with
# this repo's absolute path baked in at generation time (edit-once rule: all
# behavior lives in the launcher, on disk).
#
# Usage: make-shortcuts.sh [-c] [output-dir]     (default ~/.slipmat/shortcuts)
#   -c   also build the optional sixth, [SLIPMAT VIDEO] AUTO CROP(PiP)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CROP=0; [ "${1:-}" = "-c" ] && { CROP=1; shift; }
OUT="${1:-$HOME/.slipmat/shortcuts}"
mkdir -p "$OUT"
# files this builder made under names since retired (exact names only)
rm -f "$OUT/[SLIPMAT AUDIO] AUTO(BEST).shortcut" "$OUT/[SLIPMAT AUDIO] SPOTIFY.shortcut"

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
  # daemon is flaky under burst load — retry up to 3 times.
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

# icon colors are Shortcuts palette IDs, not RGB: video = yellow/orange,
# audio = light blue, Spotify = green — audio must never read as video
printf 'building Shortcuts for %s\n' "$REPO"
make_one "[SLIPMAT VIDEO] AUTO(BEST)"     best    4274264319 || fail=1   # yellow
make_one "[SLIPMAT VIDEO] PICKER"         picker  4271458815 || fail=1   # orange
make_one "[SLIPMAT VIDEO] STUDIO"         studio  4274264319 || fail=1   # yellow
make_one "[SLIPMAT WEBAUDIO]"             audio   1440408063 || fail=1   # light blue
make_one "[SLIPMAT SPOTIFY]"              spotify 4292093695 || fail=1   # green
[ "$CROP" = "1" ] && { make_one "[SLIPMAT VIDEO] AUTO CROP(PiP)" crop 4274264319 || fail=1; }   # yellow, optional

if [ "$fail" = "1" ]; then
  cat <<EOF

Some Shortcuts could not be signed (signing needs a Mac signed into iCloud).
No problem — shortcuts/SETUP.md walks you through creating them by hand in
about two minutes; each is a single pasted line.
EOF
  exit 1
fi
printf 'signed files in: %s\n' "$OUT"
