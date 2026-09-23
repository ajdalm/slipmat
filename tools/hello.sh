#!/bin/bash
# slipmat hello — the onboarding concierge. Three full-window pages:
#   PAGE 1  SLIPMAT marquee · where do video/audio rips land · toolchain glance
#   PAGE 2  SHORTCUTS marquee · the suite · consent · signed install with one
#           "Add Shortcut" click per shortcut · LAST STEP checklist + help
#   PAGE 3  ⌘C marquee · use-case map (which dropdown for which job)
# The window resizes itself (50×110) and each page clears the screen, so
# nothing ever scrolls out of sight. Purple = identity + questions + keys,
# green = the marquee lock-in and ✓s. Everything degrades honestly: no tty →
# plain linear text, no signing → the SETUP.md paste path.
# Test hook: SLIPMAT_HELLO_NO_OPEN=1 skips `open` + the per-shortcut pauses so
# every branch can be driven headlessly (see docs/TESTING.md).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CONF_DIR="$HOME/.slipmat"; CONF="$CONF_DIR/config"
IS_TTY=0; [ -t 1 ] && IS_TTY=1

# ---- palette (purple = slipmat's voice: identity, questions, keys) ----------
if [ "$IS_TTY" = "1" ]; then
  B=$'\033[1m'; DM=$'\033[2m'; PQ=$'\033[35m'; PB=$'\033[1;35m'; GN=$'\033[32m'; BL=$'\033[1;34m'; RS=$'\033[0m'
else B=""; DM=""; PQ=""; PB=""; GN=""; BL=""; RS=""; fi

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

# ---- Q1: video folder -------------------------------------------------------
DEF_OUT="${PREV_OUT:-$HOME/Downloads/SLIPMAT}"
ask "where" "should VIDEO rips land?"
printf '   %s[Enter]%s  %s%s%s     — or type any folder path\n' "$PB" "$RS" "$B" "$(short_home "$DEF_OUT")" "$RS"
while :; do
  printf '  %s[Enter = %s]%s ' "$DM" "$(short_home "$DEF_OUT")" "$RS"; IFS= read -r a || a=""
  [ -z "$a" ] && { OUTDIR="$DEF_OUT"; break; }
  OUTDIR="$(expand_path "$a")"
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
elif [ -n "$PREV_AUD" ]; then AUD_DEF="$PREV_AUD"; AUD_MEAN="$(short_home "$PREV_AUD")"; fi
k1="[1]"; k2="[2]"; [ "$AUD_DEF" = "1" ] && k1="[Enter/1]"; [ "$AUD_DEF" = "2" ] && k2="[Enter/2]"
printf '   %s%-9s%s  %sSlipmat download folder%s — %s%s%s\n' "$PB" "$k1" "$RS" "$B" "$RS" "$DM" "$(short_home "$OUTDIR")" "$RS"
echo
printf '   %s%-9s%s  %sAuto-import into Music.app%s — every rip lands in your\n' "$PB" "$k2" "$RS" "$B" "$RS"
printf '              library the moment it finishes: tagged, artwork in place\n'
echo
case "$AUD_DEF" in 1|2) ;; *)
  printf '   %s%-9s%s  %skeep%s %s\n\n' "$PB" "[Enter]" "$RS" "$B" "$RS" "$AUD_MEAN" ;; esac
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
echo
printf '   %s[SLIPMAT VIDEO] PICKER%s\n' "$PB" "$RS"
printf '      see the source'\''s REAL resolutions (1080p, 720p, …), pick one,\n'
printf '      the rest is automatic\n'
echo
printf '   %s[SLIPMAT VIDEO] STUDIO%s\n' "$PB" "$RS"
printf '      the picker plus a re-encode concierge: shrink or optimize the file,\n'
printf '      or crop to a PiP (remove static borders from videos). No URL needed —\n'
printf '      %s⌘C a file in Finder%s and STUDIO optimizes what'\''s already on your disk\n' "$B" "$RS"
echo
printf '   %s[SLIPMAT AUDIO] AUTO(BEST)%s\n' "$BL" "$RS"
printf '      copied link → a clean .m4a with artwork, AAC-320 via Apple'\''s encoder.\n'
printf '      320k is the highest AAC rate CDJ hardware accepts — the files are\n'
printf '      deck-compatible as delivered.\n'
echo
printf ' Installing takes %sunder a minute%s: press Enter, then click %s"Add Shortcut"%s\n' "$B" "$RS" "$B" "$RS"
printf ' each time one pops up. Four pops. That'\''s the whole job.\n'
ask "install" "the shortcut suite?"
printf '   %s[Enter/Y]%s  %sYES%s — the blissful two-click experience\n' "$PB" "$RS" "$B" "$RS"
printf '   %s[N]%s        %sNO%s  — I enjoy typing commands into Terminal by hand, every single time\n' "$PB" "$RS" "$B" "$RS"
printf '  %s[Enter = YES]%s ' "$DM" "$RS"; IFS= read -r a || a=""

INSTALLED=0
NAMES_1="[SLIPMAT VIDEO] AUTO(BEST)"
NAMES_2="[SLIPMAT VIDEO] PICKER"
NAMES_3="[SLIPMAT VIDEO] STUDIO"
NAMES_4="[SLIPMAT AUDIO] AUTO(BEST)"
if [ -z "$a" ] || [ "$a" = "y" ] || [ "$a" = "Y" ]; then
  SCDIR="$CONF_DIR/shortcuts"
  echo
  if /bin/bash "$REPO/shortcuts/make-shortcuts.sh" "$SCDIR"; then
    echo
    for i in 1 2 3 4; do
      eval "name=\$NAMES_$i"
      f="$SCDIR/$name.shortcut"
      [ -e "$f" ] || continue
      printf '   opening %s%s%s ' "$PB" "$name" "$RS"
      if [ "${SLIPMAT_HELLO_NO_OPEN:-0}" = "1" ]; then
        printf '%s(test mode — not opened)%s\n' "$DM" "$RS"
      else
        open "$f"
        printf '— click %s"Add Shortcut"%s, then %s[Enter = next]%s ' "$B" "$RS" "$DM" "$RS"
        IFS= read -r _ || true
      fi
    done
    INSTALLED=1
    echo
    printf ' %s━━━━━━━━━━━━━━━━━━━━━━━━━  LAST STEP  ━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$PB" "$RS"
    printf ' Put the shortcuts in your menu bar:\n'
    echo
    printf '   1. open the %sShortcuts%s app\n' "$B" "$RS"
    printf '   2. in the left sidebar, click the folder named %s"Menu Bar"%s\n' "$B" "$RS"
    printf '      %s(no sidebar? menu View → Show Sidebar · no "Menu Bar" folder?\n' "$DM"
    printf '       Shortcuts → Settings → Sidebar → tick "Menu Bar")%s\n' "$RS"
    printf '   3. any %s[SLIPMAT …]%s shortcuts missing from that folder? drag them in\n' "$PB" "$RS"
    printf '      from %sAll Shortcuts%s\n' "$B" "$RS"
    printf '   4. that'\''s it — the Shortcuts icon appears in the menu bar on its own\n'
    printf '      once the folder has shortcuts in it. That dropdown is slipmat now.\n'
    while :; do
      ask "ready" "— are the shortcuts in your menu bar?"
      printf '   %s[Enter/Y]%s  %sYES%s\n' "$PB" "$RS" "$B" "$RS"
      printf '   %s[H]%s        %sHELP%s — walk me through it step by step\n' "$PB" "$RS" "$B" "$RS"
      printf '   %s[N]%s        %sNO%s  — I'\''ll trigger them my own way\n' "$PB" "$RS" "$B" "$RS"
      printf '  %s[Enter = YES]%s ' "$DM" "$RS"; IFS= read -r a || a=""
      case "$a" in
        ""|y|Y) printf '   %s✓ the dropdown is live.%s\n' "$GN" "$RS"; break ;;
        n|N)    printf '   fair enough — they'\''re yours to summon however you like.\n'; break ;;
        h|H)
          echo
          printf '   %sthe walkthrough%s\n' "$PB" "$RS"
          printf '   1. Open the %sShortcuts app%s. (Closed it already? ⌘Space, type\n' "$B" "$RS"
          printf '      "Shortcuts", press Enter.)\n'
          printf '   2. Show the sidebar: menu %sView → Show Sidebar%s. Find the folder\n' "$B" "$RS"
          printf '      named %s"Menu Bar"%s. Not listed? %sShortcuts → Settings →\n' "$B" "$RS" "$B"
          printf '      Sidebar tab → tick "Menu Bar"%s.\n' "$RS"
          printf '   3. Click %sAll Shortcuts%s and find the %s[SLIPMAT …]%s cards.\n' "$B" "$RS" "$PB" "$RS"
          printf '   4. %sDrag each card onto the "Menu Bar" folder%s — drop it right on\n' "$B" "$RS"
          printf '      the folder'\''s name. (Or: select a card, press ⌘I, and tick\n'
          printf '      %s"Pin in Menu Bar"%s.)\n' "$B" "$RS"
          printf '   5. The Shortcuts icon appears in your menu bar %son its own%s once\n' "$B" "$RS"
          printf '      that folder has anything in it. Click it — slipmat lives there.\n'
          printf '\n   %s[Enter]%s  %sGot it!%s      %s[N]%s  I'\''m still confused\n' "$PB" "$RS" "$B" "$RS" "$PB" "$RS"
          printf '  %s[Enter = got it]%s ' "$DM" "$RS"; IFS= read -r a || a=""
          if [ "$a" = "n" ] || [ "$a" = "N" ]; then
            echo
            printf '   no shame — this corner of macOS is genuinely weird. Open an issue\n'
            printf '   on the slipmat GitHub repo; the developer would love to hear from\n'
            printf '   you. In the meantime, everything also works right here in the\n'
            printf '   terminal — next page shows you how.\n'
            INSTALLED=0
          else
            printf '   %s✓ the dropdown is live.%s\n' "$GN" "$RS"
          fi
          break ;;
        *) printf '   %s(Enter, Y, H or N)%s\n' "$DM" "$RS" ;;
      esac
    done
    printf '   %sFirst click on each Shortcut, macOS asks to allow it to run scripts /\n' "$DM"
    printf '   control Terminal — that'\''s the one-time permission handshake.%s\n' "$RS"
  else
    printf '   Signing didn'\''t work on this Mac (it needs an iCloud login). No drama:\n'
    printf '   %sshortcuts/SETUP.md%s builds the same four by hand — four paste blocks,\n' "$B" "$RS"
    printf '   about two minutes.\n'
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
printf ' %stry it now%s — while it'\''s fresh:\n' "$B" "$RS"
echo
if [ "$INSTALLED" = "1" ]; then
  printf '   %scopy a URL%s (address bar, share button, anywhere), then click:\n' "$B" "$RS"
  echo
  printf '   a video worth keeping forever, max quality      %s[SLIPMAT VIDEO] AUTO(BEST)%s\n' "$PB" "$RS"
  printf '   the same, but you choose 1080p / 720p / …       %s[SLIPMAT VIDEO] PICKER%s\n' "$PB" "$RS"
  printf '   something to shrink, optimize, or crop down     %s[SLIPMAT VIDEO] STUDIO%s\n' "$PB" "$RS"
  printf '   a track for your library (or your DJ crate)     %s[SLIPMAT AUDIO] AUTO(BEST)%s\n' "$BL" "$RS"
  echo
  printf '   %sno URL needed:%s\n' "$B" "$RS"
  printf '   ⌘C a bloated file in Finder, click %sSTUDIO%s — optimize or PiP-crop\n' "$PB" "$RS"
  printf '   what'\''s already on your disk\n' 
else
  printf '   %scopy a URL%s, then in this terminal:\n' "$B" "$RS"
  echo
  printf '   %s./slipmat <url> best%s          a video worth keeping, max quality, no questions\n' "$B" "$RS"
  printf '   %s./slipmat <url> auto%s          the same, but you choose 1080p / 720p / …\n' "$B" "$RS"
  printf '   %s./slipmat <url> studio%s        shrink, optimize, or crop — the concierge\n' "$B" "$RS"
  printf '   %s./slipmat <file> studio%s       the concierge for a bloated file already on disk\n' "$B" "$RS"
  printf '   %s./slipmat audio <url>%s         a track for your library (or your DJ crate)\n' "$B" "$RS"
fi
echo
printf ' Every rip prints a receipt — what the source really served, what landed,\n'
printf ' how long it took. Logs live in ~/.slipmat/logs.\n'
echo
printf ' %sEnd of onboarding. Go rip something great.%s\n' "$PB" "$RS"
echo
