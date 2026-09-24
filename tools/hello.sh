#!/bin/bash
# slipmat hello — the onboarding concierge. Three full-window pages:
#   PAGE 1  SLIPMAT marquee · where do video/audio rips land · toolchain glance
#           · optional Spotify login
#   PAGE 2  SHORTCUTS marquee · the suite · consent · signed install: the pop-ups
#           chain (each "Add Shortcut" opens the next) · LAST STEP: find the
#           menu-bar icon, with a help ladder
#   PAGE 3  ⌘C marquee · use-case map (which dropdown for which job)
# The window resizes itself (50×110) and each page clears the screen, so
# nothing ever scrolls out of sight. Purple = identity + questions + keys and
# the VIDEO shortcuts, sky blue = the AUDIO shortcuts, green = ✓s. Answers are
# keycap chips glued to their label, so a row reads "press this", never "type
# this word". Everything degrades honestly: no tty →
# plain linear text, no signing → the SETUP.md paste path.
# Test hook: SLIPMAT_HELLO_NO_OPEN=1 skips `open`, the import wait and the
# Spotify login so every branch can be driven headlessly (docs/TESTING.md).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CONF_DIR="$HOME/.slipmat"; CONF="$CONF_DIR/config"
IS_TTY=0; [ -t 1 ] && IS_TTY=1

# ---- palette (purple = slipmat's voice: identity, questions, keys) ----------
# BL is 256-color sky blue: plain ANSI blue (34) draws close to violet in
# Terminal.app, and audio must never read as video
if [ "$IS_TTY" = "1" ]; then
  B=$'\033[1m'; DM=$'\033[2m'; PQ=$'\033[35m'; PB=$'\033[1;35m'; GN=$'\033[32m'; BL=$'\033[1;38;5;39m'; RS=$'\033[0m'
  KC=$'\033[1;7;35m'   # keycap: a solid purple block
else B=""; DM=""; PQ=""; PB=""; GN=""; BL=""; RS=""; KC=""; fi

# a keycap chip, one fixed width so every label starts in the same column and
# sits right against its key: [ Enter ] install   [   n   ] skip
chip() {
  local k="$1" l r
  l=$(( (5 - ${#k}) / 2 )); r=$(( 5 - ${#k} - l ))
  if [ "$IS_TTY" = "1" ]; then printf '%s %*s%s%*s %s' "$KC" "$l" '' "$k" "$r" '' "$RS"
  else printf '[%*s%s%*s]' "$l" '' "$k" "$r" ''; fi
}
opt() {  # opt KEY LABEL [rest]
  printf '   %s %s%s%s%s\n' "$(chip "$1")" "$B" "$2" "$RS" "${3:+ — $3}"
}

# ---- window + pages ---------------------------------------------------------
# Terminal.app honors the xterm resize escape; 50×110 holds every page whole.
[ "$IS_TTY" = "1" ] && printf '\033[8;50;110t'
page() { [ "$IS_TTY" = "1" ] && printf '\033[2J\033[H' || printf '\n\n'; }

# ---- the marquees -----------------------------------------------------------
art_slipmat() {
cat <<'EOF'
 ███████╗██╗     ██╗██████╗ ███╗   ███╗ █████╗ ████████╗
 ██╔════╝██║     ██║██╔══██╗████╗ ████║██╔══██╗╚══██╔══╝
 ███████╗██║     ██║██████╔╝██╔████╔██║███████║   ██║
 ╚════██║██║     ██║██╔═══╝ ██║╚██╔╝██║██╔══██║   ██║
 ███████║███████╗██║██║     ██║ ╚═╝ ██║██║  ██║   ██║
 ╚══════╝╚══════╝╚═╝╚═╝     ╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝
EOF
}
art_shortcuts() {
cat <<'EOF'
 ███████╗██╗  ██╗ ██████╗ ██████╗ ████████╗ ██████╗██╗   ██╗████████╗███████╗
 ██╔════╝██║  ██║██╔═══██╗██╔══██╗╚══██╔══╝██╔════╝██║   ██║╚══██╔══╝██╔════╝
 ███████╗███████║██║   ██║██████╔╝   ██║   ██║     ██║   ██║   ██║   ███████╗
 ╚════██║██╔══██║██║   ██║██╔══██╗   ██║   ██║     ██║   ██║   ██║   ╚════██║
 ███████║██║  ██║╚██████╔╝██║  ██║   ██║   ╚██████╗╚██████╔╝   ██║   ███████║
 ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═════╝    ╚═╝   ╚══════╝
EOF
}
art_cmdc() {
# the ⌘ from its real geometry (crossing strokes → four corner loops) and a
# C built at the same 9-row pixel scale so the pair reads as one wordmark.
cat <<'EOF'
 ██████████      ██████████         ██████████████
 ██      ██      ██      ██       ████████████████
 ██████████████████████████      ██████
         ██      ██              ██████
         ██      ██              ██████
         ██      ██              ██████
 ██████████████████████████      ██████
 ██      ██      ██      ██       ████████████████
 ██████████      ██████████         ██████████████
EOF
}
marquee() {
  # matrix-style decode of whatever block art arrives on stdin: every glyph
  # rains as a random character in dim purple, then locks in bright, sweeping
  # left to right. ~1s, tty only; plain purple print everywhere else.
  _art=$(cat)
  if [ "$IS_TTY" = "1" ] && [ "${SLIPMAT_NO_FX:-0}" != "1" ] && command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$_art" | python3 -c '
import random, sys, time
lines = [l.rstrip("\n") for l in sys.stdin]
w = max(len(l) for l in lines)
lines = [l.ljust(w) for l in lines]
rain = "01ｱｳｴｵｶｷｹｺｻｼｽｾｿﾀﾂﾃﾅﾆﾇﾈﾊﾋﾎﾏﾐﾑﾒﾓﾔﾕﾗﾘﾜ01"
jit = [[random.randint(0, 7) for _ in range(w)] for _ in lines]
out = sys.stdout
frames = (w // 4) + 10
for f in range(frames):
    if f: out.write("\033[%dA" % len(lines))
    for y, l in enumerate(lines):
        row = []
        for x, ch in enumerate(l):
            t = x // 4 + jit[y][x]
            if ch == " ":            row.append(" ")
            elif f >= t + 4:         row.append("\033[1;35m%s\033[0m" % ch)
            elif f >= t:             row.append("\033[2;35m%s\033[0m" % random.choice(rain))
            else:                    row.append(" ")
        out.write("".join(row) + "\n")
    out.flush()
    time.sleep(0.035)
' 2>/dev/null && return
  fi
  printf '%s%s%s\n' "$PQ" "$_art" "$RS"
}

expand_path() {  # ~ and relative → absolute
  case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac
}
short_home() { case "$1" in "$HOME"/*) printf '~/%s' "${1#$HOME/}" ;; *) printf '%s' "$1" ;; esac; }

ask() {  # a question, all in slipmat purple
  printf '\n%s%s %s%s\n' "$PB" "$1" "$2" "$RS"
}

# ============================ PAGE 1 — SLIPMAT ===============================
page
echo
art_slipmat | marquee
echo
printf ' %sHi. I'\''m slipmat — a versatile multimedia archival tool.%s\n' "$PB" "$RS"
if [ -f "$CONF" ]; then
  printf ' %s(rerunning setup — Enter keeps your current answers)%s\n' "$DM" "$RS"
else
  printf ' Let'\''s take 60 seconds to set you up. Enter always takes the\n'
  printf ' sensible default, and every answer lives in ~/.slipmat/config.\n'
fi

# ---- the previous answers (a rerun keeps them unless you type something new) -
prev() { [ -f "$CONF" ] || return 0; ( . "$CONF" >/dev/null 2>&1; eval "printf '%s' \"\${$1:-}\"" ); }
PREV_OUT="$(prev OUTDIR)"; PREV_AUD="$(prev AUDIO_OUTDIR)"; PREV_AUTO="$(prev AUDIO_AUTO_ADD)"

# a rips folder INSIDE slipmat's own folder would mix media into a git clone
# (one careless commit away from uploading it) — never offer or accept one
in_repo() { case "$1/" in "$REPO/"*) return 0 ;; esac; return 1; }

# ---- Q1: video folder -------------------------------------------------------
DEF_OUT="${PREV_OUT:-$HOME/Downloads/SLIPMAT}"
if in_repo "$DEF_OUT"; then
  printf '\n %s(your saved folder is inside slipmat'\''s own app folder — suggesting a separate one)%s\n' "$DM" "$RS"
  DEF_OUT="$HOME/Downloads/SLIPMAT"
fi
ask "where" "should VIDEO rips land?"
opt "Enter" "$(short_home "$DEF_OUT")"
printf '   %s(or type any folder path)%s\n' "$DM" "$RS"
while :; do
  printf '  %s[Enter = %s]%s ' "$DM" "$(short_home "$DEF_OUT")" "$RS"; IFS= read -r a || a=""
  [ -z "$a" ] && { OUTDIR="$DEF_OUT"; break; }
  OUTDIR="$(expand_path "$a")"
  if in_repo "$OUTDIR"; then
    printf '   that'\''s inside slipmat'\''s own app folder — pick a folder outside %s\n' "$(short_home "$REPO")"
    continue
  fi
  mkdir -p "$OUTDIR" 2>/dev/null && [ -w "$OUTDIR" ] && break
  printf '   can'\''t create/write %s — try another path\n' "$OUTDIR"
done
mkdir -p "$OUTDIR" 2>/dev/null
printf '   %s✓ video → %s%s\n' "$GN" "$OUTDIR" "$RS"

# ---- Q2: audio --------------------------------------------------------------
AUDIO_OUTDIR=""; AUDIO_AUTO_ADD=""
ask "and" "AUDIO rips?"
echo
# Enter wears the previous answer: 1, 2, or the custom folder you typed last time
AUD_DEF=1; AUD_MEAN="Slipmat folder"
if [ -n "$PREV_AUTO" ]; then AUD_DEF=2; AUD_MEAN="Music.app"
elif [ -n "$PREV_AUD" ] && ! in_repo "$PREV_AUD"; then AUD_DEF="$PREV_AUD"; AUD_MEAN="$(short_home "$PREV_AUD")"; fi
k1="1"; k2="2"; [ "$AUD_DEF" = "1" ] && k1="Enter"; [ "$AUD_DEF" = "2" ] && k2="Enter"
opt "$k1" "the slipmat download folder" "$(short_home "$OUTDIR")"
opt "$k2" "straight into Music.app" "every rip lands in your library the"
printf '             moment it finishes: tagged, artwork in place\n'
case "$AUD_DEF" in 1|2) ;; *) opt "Enter" "keep" "$AUD_MEAN" ;; esac
printf '   %s(or type any other folder path)%s\n' "$DM" "$RS"
while :; do
  printf '  %s[Enter = %s]%s ' "$DM" "$AUD_MEAN" "$RS"; IFS= read -r a || a=""
  [ -z "$a" ] && a="$AUD_DEF"
  case "$a" in
    ""|1) printf '   %s✓ audio → %s%s\n' "$GN" "$OUTDIR" "$RS"; break ;;
    2|m|M)
      for cand in \
        "$HOME/Music/Music/Media.localized/Automatically Add to Music.localized" \
        "$HOME/Music/iTunes/iTunes Media/Automatically Add to iTunes.localized"; do
        [ -d "$cand" ] && { AUDIO_AUTO_ADD="$cand"; break; }
      done
      if [ -n "$AUDIO_AUTO_ADD" ]; then
        printf '   %s✓ audio → Music library (fully tagged before Music ever sees the file)%s\n' "$GN" "$RS"
      else
        printf '   Music'\''s "Automatically Add" folder isn'\''t where it usually is —\n'
        printf '   open Music.app once (it creates the folder), then rerun `slipmat hello`.\n'
        printf '   For now audio lands beside video: %s\n' "$OUTDIR"
      fi
      break ;;
    *)
      AUDIO_OUTDIR="$(expand_path "$a")"
      if in_repo "$AUDIO_OUTDIR"; then
        printf '   that'\''s inside slipmat'\''s own app folder — pick a folder outside %s\n' "$(short_home "$REPO")"
        AUDIO_OUTDIR=""; continue
      fi
      mkdir -p "$AUDIO_OUTDIR" 2>/dev/null && [ -w "$AUDIO_OUTDIR" ] \
        && { printf '   %s✓ audio → %s%s\n' "$GN" "$AUDIO_OUTDIR" "$RS"; break; }
      printf '   can'\''t create/write %s — try another path\n' "$AUDIO_OUTDIR" ;;
  esac
done

# ---- write config (managed block; user lines outside it survive) ------------
mkdir -p "$CONF_DIR"
TMP="$CONF_DIR/.config.new.$$"
{ [ -f "$CONF" ] && sed '/^# ── set by slipmat hello/,/^# ── end slipmat hello/d' "$CONF"
  printf '# ── set by slipmat hello (rerun `slipmat hello` to change) ──\n'
  # %q: the config is SOURCED by the engines, so a folder name holding a quote,
  # $ or backtick must be escaped, not pasted raw into shell code
  printf 'OUTDIR=%q\n' "$OUTDIR"
  [ -n "$AUDIO_OUTDIR"   ] && printf 'AUDIO_OUTDIR=%q\n' "$AUDIO_OUTDIR"
  [ -n "$AUDIO_AUTO_ADD" ] && printf 'AUDIO_AUTO_ADD=%q\n' "$AUDIO_AUTO_ADD"
  printf '# ── end slipmat hello ──\n'
} > "$TMP" && mv "$TMP" "$CONF"
printf '   %ssaved → %s%s\n' "$DM" "$CONF" "$RS"

# ---- toolchain glance -------------------------------------------------------
echo
printf '%s the toolchain%s\n' "$B" "$RS"
ok=1
if [ -x /opt/homebrew/bin/ffmpeg ] || command -v ffmpeg >/dev/null 2>&1; then
  printf '   %s✓%s ffmpeg\n' "$GN" "$RS"
else ok=0; printf '   ✗ ffmpeg — install:  brew install ffmpeg\n'; fi
if [ -x /opt/homebrew/bin/yt-dlp ] || command -v yt-dlp >/dev/null 2>&1; then
  printf '   %s✓%s yt-dlp\n' "$GN" "$RS"
else ok=0; printf '   ✗ yt-dlp — install:  brew install yt-dlp\n'; fi
if command -v uv >/dev/null 2>&1 || [ -x /opt/homebrew/bin/uv ]; then
  printf '   %s✓%s uv %s(for Spotify rips)%s\n' "$GN" "$RS" "$DM" "$RS"
else
  printf '   · uv — only needed for Spotify rips:  brew install uv\n'
fi
[ "$ok" = "0" ] && printf '   %s(`slipmat doctor` rechecks everything whenever you like)%s\n' "$DM" "$RS"
if ls "$HOME/Library/Application Support/Firefox/Profiles" >/dev/null 2>&1; then
  printf '   %s✓%s Firefox — slipmat borrows its cookies. %sStay logged in to your video\n' "$GN" "$RS" "$B"
  printf '     sites in Firefox%s and gated streams (members-only, age-restricted,\n' "$RS"
  printf '     premium) just work.\n'
else
  printf '   · no Firefox — slipmat works without it. Want gated streams? %sLog in\n' "$B"
  printf '     to your video sites in Firefox%s; slipmat borrows its cookies.\n' "$RS"
  printf '     %s(different browser? set COOKIE_BROWSER in ~/.slipmat/config)%s\n' "$DM" "$RS"
fi

# ---- Spotify: log in now, so the SPOTIFY shortcut works on its first click ---
# (the login is saved by the ripper; a Mac that already ran mr-rippah has it)
SPOT_CREDS="$HOME/Library/Caches/Mr. Rippah/credentials.json"
if [ -s "$SPOT_CREDS" ]; then
  printf '   %s✓%s Spotify — already logged in; the SPOTIFY shortcut is ready\n' "$GN" "$RS"
elif command -v uv >/dev/null 2>&1 || [ -x /opt/homebrew/bin/uv ]; then
  ask "spotify" "— log in now? (Premium account; skip if you don't use Spotify)"
  opt "Enter" "log in" "sets up the Spotify ripper, then opens Spotify's login page"
  opt "s" "skip" "not now (the first Spotify rip asks instead)"
  printf '  %s[Enter = log in]%s ' "$DM" "$RS"; IFS= read -r a || a=""
  case "$a" in
    s|S|n|N) printf '   %sskipped — `slipmat spotify --login` any time%s\n' "$DM" "$RS" ;;
    *)
      if [ "${SLIPMAT_HELLO_NO_OPEN:-0}" = "1" ]; then
        printf '   %s(test mode — no login)%s\n' "$DM" "$RS"
      else
        # Ctrl-C here ends only the login, not the setup
        trap 'true' INT
        "$REPO/engine/slipmat-spotify" --login || printf '   %sno login yet — the first Spotify rip asks again%s\n' "$DM" "$RS"
        trap - INT
      fi ;;
  esac
else
  printf '   · Spotify — needs uv first:  brew install uv   then  slipmat spotify --login\n'
fi

if [ "$IS_TTY" = "1" ]; then
  printf '\n  %s[Enter = on to the good part]%s ' "$DM" "$RS"; IFS= read -r _ || true
fi

# =========================== PAGE 2 — SHORTCUTS ==============================
page
echo
art_shortcuts | marquee
echo
printf ' slipmat works best as a %sshortcut suite%s: copy %s[⌘C]%s a URL — or a local\n' "$PB" "$RS" "$PB" "$RS"
printf ' file if using STUDIO — then trigger slipmat from your menu bar.\n'
echo
printf '   %s[SLIPMAT VIDEO] AUTO(BEST)%s\n' "$PB" "$RS"
printf '      the best quality your machine can actually play, ripped bulletproof —\n'
printf '      zero questions asked\n'
printf '   %s[SLIPMAT VIDEO] PICKER%s\n' "$PB" "$RS"
printf '      see the source'\''s REAL resolutions (1080p, 720p, …), pick one,\n'
printf '      the rest is automatic\n'
printf '   %s[SLIPMAT VIDEO] STUDIO%s\n' "$PB" "$RS"
printf '      the picker plus a re-encode concierge: shrink or optimize the file,\n'
printf '      or crop to a PiP (remove static borders from videos). No URL needed —\n'
printf '      %s⌘C a file in Finder%s and STUDIO optimizes what'\''s already on your disk\n' "$B" "$RS"
echo
printf '   %s[SLIPMAT WEBAUDIO]%s\n' "$BL" "$RS"
printf '      rips audio from YouTube, SoundCloud, etc. → a clean .m4a with artwork,\n'
printf '      AAC-320 via Apple'\''s encoder — the highest AAC rate CDJ hardware\n'
printf '      accepts, so the files are deck-ready as delivered\n'
printf '   %s[SLIPMAT SPOTIFY]%s\n' "$BL" "$RS"
printf '      rips a Spotify playlist (or album, or single track) → the same\n'
printf '      deck-ready .m4a, straight from Spotify'\''s 320k stream. Needs Spotify\n'
printf '      Premium. %s(powered by cvdub'\''s mr-rippah)%s\n' "$DM" "$RS"
echo
printf ' Installing takes %sunder a minute%s: press Enter here, then Enter again on each\n' "$B" "$RS"
printf ' %s"Add Shortcut"%s pop-up — the next one pops up by itself. Five in a row.\n' "$B" "$RS"
ask "install" "the shortcut suite?"
opt "Enter" "install" "the blissful two-click experience"
opt "n" "skip" "I enjoy typing commands into Terminal by hand, every single time"
printf '  %s[Enter = install]%s ' "$DM" "$RS"; IFS= read -r a || a=""

# INSTALLED: 0 = declined or failed · 1 = in the menu bar · 2 = added, but the
# menu bar isn't showing them yet (page 3 then teaches both routes)
INSTALLED=0
NAMES_1="[SLIPMAT VIDEO] AUTO(BEST)"
NAMES_2="[SLIPMAT VIDEO] PICKER"
NAMES_3="[SLIPMAT VIDEO] STUDIO"
NAMES_4="[SLIPMAT WEBAUDIO]"
NAMES_5="[SLIPMAT SPOTIFY]"
# names older installs used — the rename leaves them behind as duplicates
OLD_NAMES='[SLIPMAT AUDIO] AUTO(BEST)
[SLIPMAT AUDIO] SPOTIFY'
color_of() { case "$1" in *VIDEO*) printf '%s' "$PB" ;; *) printf '%s' "$BL" ;; esac; }
lib_sig() { shortcuts list --show-identifiers 2>/dev/null | cksum; }

if [ -z "$a" ] || [ "$a" = "y" ] || [ "$a" = "Y" ]; then
  SCDIR="$CONF_DIR/shortcuts"
  echo
  if /bin/bash "$REPO/shortcuts/make-shortcuts.sh" "$SCDIR" >/dev/null; then
    echo
    printf ' %sadding them%s — press Enter (or click %s"Add Shortcut"%s) on each pop-up.\n' "$B" "$RS" "$B" "$RS"
    printf ' %s(a shortcut you already had asks "Replace" — then come back here and\n' "$DM"
    printf '  press Enter)%s\n' "$RS"
    echo
    # Shortcuts files each new arrival at the TOP of the menu-bar dropdown, so
    # they go in bottom-up: AUTO(BEST), added last, ends up first in line
    for i in 5 4 3 2 1; do
      eval "name=\$NAMES_$i"
      f="$SCDIR/$name.shortcut"
      [ -e "$f" ] || continue
      C="$(color_of "$name")"
      if [ "${SLIPMAT_HELLO_NO_OPEN:-0}" = "1" ]; then
        printf '   %s·%s %s%s%s  %s(test mode — not opened)%s\n' "$DM" "$RS" "$C" "$name" "$RS" "$DM" "$RS"
        continue
      fi
      printf '   %s…%s %s%s%s  %swaiting for "Add Shortcut"%s' "$DM" "$RS" "$C" "$name" "$RS" "$DM" "$RS"
      before="$(lib_sig)"; open "$f"
      # the pop-up is in front, not this window: advance when the Shortcuts
      # library changes (the add landed) — or on Enter typed here (a Replace
      # doesn't always change the library). Three minutes, then move on.
      got=""; t=0
      if [ "$IS_TTY" = "1" ]; then
        while [ "$t" -lt 180 ]; do
          if IFS= read -r -t 1 _; then got=enter; break; fi
          t=$((t+1))
          [ "$(lib_sig)" != "$before" ] && { got=added; break; }
        done
      else sleep 2; got=enter; fi
      [ "$got" = "enter" ] && printf '\033[1A'
      case "$got" in
        added) printf '\r\033[K   %s✓%s %s%s%s  %sadded%s\n' "$GN" "$RS" "$C" "$name" "$RS" "$DM" "$RS" ;;
        enter) printf '\r\033[K   %s✓%s %s%s%s\n' "$GN" "$RS" "$C" "$name" "$RS" ;;
        *)     printf '\r\033[K   %s?%s %s%s%s  %sno answer — rerun slipmat hello to try again%s\n' "$DM" "$RS" "$C" "$name" "$RS" "$DM" "$RS" ;;
      esac
    done
    # the pop-ups left Shortcuts in front — bring this window back
    [ "${SLIPMAT_HELLO_NO_OPEN:-0}" = "1" ] || open -b "${__CFBundleIdentifier:-com.apple.Terminal}" 2>/dev/null
    INSTALLED=1
    stale="$(shortcuts list 2>/dev/null | grep -Fx "$OLD_NAMES")"
    if [ -n "$stale" ]; then
      echo
      printf ' %srenamed since your last install%s — delete the old ones in the Shortcuts\n' "$B" "$RS"
      printf ' app (right-click → Delete):\n'
      printf '%s\n' "$stale" | while IFS= read -r o; do printf '   %s%s%s\n' "$DM" "$o" "$RS"; done
    fi
    if [ "$IS_TTY" = "1" ]; then
      printf '\n  %s[Enter = last step]%s ' "$DM" "$RS"; IFS= read -r _ || true
    fi

    # ------------------------------ LAST STEP ---------------------------------
    page
    echo
    printf ' %s━━━━━━━━━━━━━━━━━━━━━━━━━  LAST STEP  ━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$PB" "$RS"
    echo
    printf ' The shortcuts are already pinned to your menu bar. Find them:\n'
    echo
    printf '   look at the %stop-right of your screen%s, near the clock and Wi-Fi, for\n' "$B" "$RS"
    printf '   the %sShortcuts icon%s — two stacked, tilted squares. Click it: the five\n' "$B" "$RS"
    printf '   %s[SLIPMAT …]%s shortcuts are listed right there. That dropdown is slipmat.\n' "$PB" "$RS"
    while :; do
      ask "ready" "— do you see them?"
      opt "Enter" "yes" "the dropdown is live"
      opt "h" "help" "no icon, or no slipmat in the dropdown"
      opt "n" "skip" "I'll trigger them my own way"
      printf '  %s[Enter = yes]%s ' "$DM" "$RS"; IFS= read -r a || a=""
      case "$a" in
        ""|y|Y) printf '   %s✓ the dropdown is live.%s\n' "$GN" "$RS"; break ;;
        n|N)    printf '   fair enough — they'\''re yours to summon however you like.\n'; break ;;
        h|H)
          echo
          printf '   %sno Shortcuts icon in the menu bar?%s\n' "$PB" "$RS"
          printf '   · %sMacBook with a notch:%s a full menu bar hides icons behind the\n' "$B" "$RS"
          printf '     notch. Hold ⌘ and drag icons you don'\''t need off the bar (or quit\n'
          printf '     an app that lives up there) — the Shortcuts icon slides into view.\n'
          printf '   · %snewer macOS:%s if System Settings has a %sMenu Bar%s section, make\n' "$B" "$RS" "$B" "$RS"
          printf '     sure Shortcuts is allowed there.\n'
          echo
          printf '   %sicon there, but no [SLIPMAT …] in its dropdown?%s\n' "$PB" "$RS"
          printf '   1. open the %sShortcuts%s app (⌘Space, type "Shortcuts", Enter)\n' "$B" "$RS"
          printf '   2. in the sidebar, click the %s"Menu Bar"%s folder %s(no sidebar? View →\n' "$B" "$RS" "$DM"
          printf '      Show Sidebar · no folder? Shortcuts → Settings → tick "Menu Bar")%s\n' "$RS"
          printf '   3. drag each %s[SLIPMAT …]%s card from %sAll Shortcuts%s onto that folder\n' "$PB" "$RS" "$B" "$RS"
          printf '      %s(or select a card, press ⌘I, tick "Pin in Menu Bar")%s\n' "$DM" "$RS"
          echo
          opt "Enter" "got it" "found them"
          opt "n" "still stuck"
          printf '  %s[Enter = got it]%s ' "$DM" "$RS"; IFS= read -r a || a=""
          if [ "$a" = "n" ] || [ "$a" = "N" ]; then
            echo
            printf '   no shame — this corner of macOS is genuinely weird. Open an issue\n'
            printf '   on the slipmat GitHub repo; the developer would love to hear from\n'
            printf '   you. Your shortcuts are installed either way — next page shows\n'
            printf '   how to use them, plus a terminal fallback in the meantime.\n'
            INSTALLED=2
          else
            printf '   %s✓ the dropdown is live.%s\n' "$GN" "$RS"
          fi
          break ;;
        *) printf '   %s(Enter, h or n)%s\n' "$DM" "$RS" ;;
      esac
    done
    echo
    printf '   %sfirst click of each shortcut:%s macOS asks whether to allow it — click\n' "$B" "$RS"
    printf '   Allow (Always Allow where offered). Once per shortcut; reinstalling one\n'
    printf '   resets that, so it asks once more.\n'
  else
    printf '   Signing didn'\''t work on this Mac (it needs an iCloud login). No drama:\n'
    printf '   %sshortcuts/SETUP.md%s builds the same five by hand — five short blocks,\n' "$B" "$RS"
    printf '   about three minutes.\n'
  fi
else
  printf '   suit yourself — the terminal'\''s all yours.\n'
  printf '   If you change your mind: %sslipmat hello%s — I'\''ll get your menu-bar\n' "$PB" "$RS"
  printf '   shortcuts set up.\n'
fi
if [ "$IS_TTY" = "1" ]; then
  printf '\n  %s[Enter = finish]%s ' "$DM" "$RS"; IFS= read -r _ || true
fi

# ============================== PAGE 3 — ⌘C =================================
page
echo
art_cmdc | marquee
echo
printf ' %s⌘C%s %s& hit the menu bar.%s\n' "$PB" "$RS" "$B" "$RS"
printf ' A URL, or a file in Finder — same move.\n'
echo
menu_map() {
  printf '   a video worth keeping forever, max quality      %s[SLIPMAT VIDEO] AUTO(BEST)%s\n' "$PB" "$RS"
  printf '   the same, but you choose 1080p / 720p / …       %s[SLIPMAT VIDEO] PICKER%s\n' "$PB" "$RS"
  printf '   something to shrink, optimize, or crop down     %s[SLIPMAT VIDEO] STUDIO%s\n' "$PB" "$RS"
  printf '   a track for your library (or your DJ crate)     %s[SLIPMAT WEBAUDIO]%s\n' "$BL" "$RS"
  printf '   a whole Spotify playlist (or album, or track)   %s[SLIPMAT SPOTIFY]%s\n' "$BL" "$RS"
}
if [ "$INSTALLED" = "1" ]; then
  printf ' %stry it now%s — while it'\''s fresh:\n' "$B" "$RS"
  echo
  printf '   %scopy a URL%s (address bar, share button, anywhere), then click the\n' "$B" "$RS"
  printf '   Shortcuts icon in your menu bar and pick:\n'
  echo
  menu_map
  echo
  printf '   %sno URL needed:%s\n' "$B" "$RS"
  printf '   ⌘C a bloated file in Finder, click %sSTUDIO%s — optimize or PiP-crop\n' "$PB" "$RS"
  printf '   what'\''s already on your disk\n'
elif [ "$INSTALLED" = "2" ]; then
  printf ' %sonce slipmat shows up in your menu bar%s: copy a URL, click the Shortcuts\n' "$B" "$RS"
  printf ' icon, and pick:\n'
  echo
  menu_map
  echo
  printf ' %suntil then%s, the same moves from this terminal (copy a URL first):\n' "$B" "$RS"
  printf '   %s./slipmat <url> best%s   ·   %s./slipmat audio <url>%s   ·   %s./slipmat spotify <link>%s\n' "$B" "$RS" "$B" "$RS" "$B" "$RS"
else
  printf ' %stry it now%s — copy a URL, then in this terminal:\n' "$B" "$RS"
  echo
  printf '   %s./slipmat <url> best%s          a video worth keeping, max quality, no questions\n' "$B" "$RS"
  printf '   %s./slipmat <url> auto%s          the same, but you choose 1080p / 720p / …\n' "$B" "$RS"
  printf '   %s./slipmat <url> studio%s        shrink, optimize, or crop — the concierge\n' "$B" "$RS"
  printf '   %s./slipmat <file> studio%s       the concierge for a bloated file already on disk\n' "$B" "$RS"
  printf '   %s./slipmat audio <url>%s         a track for your library (or your DJ crate)\n' "$B" "$RS"
  printf '   %s./slipmat spotify <link>%s      a Spotify playlist, album or track\n' "$B" "$RS"
fi
echo
printf ' Every rip prints a receipt — what the source really served, what landed,\n'
printf ' how long it took. Logs live in ~/.slipmat/logs.\n'
echo
printf ' %sEnd of onboarding. Go rip something great.%s\n' "$PB" "$RS"
echo
