#!/bin/bash
# smoke.sh — `slipmat smoke`: the offline battery. Run it before every commit.
#
# Builds three tiny synthetic clips (a clean vp9, a rotated phone-style h264, a
# clip with broken frame timestamps), runs the REAL engine on them under a
# throwaway HOME, and prints one PASS/FAIL line per check. About a minute, no
# network, nothing touches your real folders except one read-only sweep of your
# own run logs. Exit 0 = every check green.
#   -k   keep the scratch folder (its path is printed)
#   -v   print the engine's output under any FAIL
# The checks encode rules that once broke in the field; a change that violates
# one fails here instead of in someone's rip.
set -u
KEEP=0; VERB=0
while getopts "kv" _o; do case $_o in k) KEEP=1 ;; v) VERB=1 ;; *) echo "usage: slipmat smoke [-k] [-v]"; exit 2 ;; esac; done
SELF="$0"; while [ -L "$SELF" ]; do _l=$(readlink "$SELF"); case "$_l" in /*) SELF="$_l" ;; *) SELF="$(dirname "$SELF")/$_l" ;; esac; done
REPO="${SLIPMAT_REPO:-$(cd "$(dirname "$SELF")/.." && pwd)}"   # SLIPMAT_REPO: test a staged copy of this script
ENGINE="$REPO/engine/slipmat-video"
REAL_HOME="$HOME"
FFMPEG=/opt/homebrew/bin/ffmpeg;  [ -x "$FFMPEG" ]  || FFMPEG="$(command -v ffmpeg  || echo ffmpeg)"
FFPROBE=/opt/homebrew/bin/ffprobe; [ -x "$FFPROBE" ] || FFPROBE="$(command -v ffprobe || echo ffprobe)"
YTDLP=/opt/homebrew/bin/yt-dlp;   [ -x "$YTDLP" ]   || YTDLP="$(command -v yt-dlp  || echo yt-dlp)"
T0=$SECONDS
S="${TMPDIR:-/tmp}/slipmat-smoke.$$"; FX="$S/fixtures"; FH="$S/home"; OUT="$S/out"
mkdir -p "$FX" "$FH/.slipmat" "$OUT" || { echo "smoke: cannot create scratch under ${TMPDIR:-/tmp}"; exit 2; }
printf 'OUTDIR="%s"\nUSE_COOKIES=0\nTERM_SIZE=""\n' "$OUT" > "$FH/.slipmat/config"
DAY=$(date +%Y-%m-%d); LOGS="$FH/.slipmat/logs/$DAY"
PASS=0; FAIL=0; SKIP=0
G='\033[32m'; R='\033[31m'; D='\033[2m'; B='\033[1m'; Z='\033[0m'
[ -t 1 ] || { G=''; R=''; D=''; B=''; Z=''; }
pass() { PASS=$((PASS+1)); printf '  %b✓%b %s\n' "$G" "$Z" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %b✗ FAIL%b %s\n' "$R" "$Z" "$1"; [ "$VERB" = "1" ] && [ -n "${2:-}" ] && sed 's/^/        /' "$2" | tail -40; }
skip() { SKIP=$((SKIP+1)); printf '  %b·%b %s %b(skipped)%b\n' "$D" "$Z" "$1" "$D" "$Z"; }
# the one csv read smoke does itself — strip ffprobe 8's trailing comma the way the engine does
vcodec() { "$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null | sed 's/,$//'; }
newest_log() { ls -t "$LOGS"/*.log 2>/dev/null | head -1; }
# every probed value in a run log is comma-free (the ffprobe 8 side-data regression)
comma_clean() { ! grep -q ',p (\|h264,\|/[0-9]*,' "$1" 2>/dev/null; }
cleanup() { [ "$KEEP" = "1" ] || rm -rf "$S"; }
trap cleanup EXIT

FFV=$("$FFMPEG" -version 2>/dev/null | head -1 | awk '{print $3}'); YTV=$("$YTDLP" --version 2>/dev/null)
printf '%bSLIPMAT smoke%b · ffmpeg %s · yt-dlp %s · offline\n' "$B" "$Z" "${FFV:-?}" "${YTV:-?}"

# ---- 1. every script parses -------------------------------------------------
_bad=""; _n=0
for _f in "$REPO"/slipmat "$REPO"/engine/slipmat-video "$REPO"/engine/slipmat-audio "$REPO"/engine/slipmat-spotify \
          "$REPO"/tools/*.sh "$REPO"/shortcuts/make-shortcuts.sh; do
  [ -f "$_f" ] || continue; _n=$((_n+1))
  bash -n "$_f" 2>/dev/null || _bad="$_bad $(basename "$_f")"
done
if [ -z "$_bad" ]; then pass "syntax: $_n scripts parse"; else fail "syntax:$_bad"; fi

# ---- 2. banned download flags stay out of the code (comments may name them) --
if grep -n -- '--concurrent-fragments\|--retry-sleep' "$ENGINE" "$REPO/engine/slipmat-audio" 2>/dev/null | grep -qv ':[[:space:]]*#'; then
  fail "banned yt-dlp flags present (--concurrent-fragments / --retry-sleep draw 503 walls)"
else pass "banned yt-dlp flags absent (--concurrent-fragments, --retry-sleep)"; fi

# ---- 3. a hand Ctrl-C mid-download is the step-down key, never "CDN weather" --
if grep -q 'Interrupted by user' "$ENGINE"; then pass "engine recognizes yt-dlp's 'Interrupted by user' (Ctrl-C = step down, not a CDN error)"
else fail "engine does not recognize 'Interrupted by user' — a hand Ctrl-C would be reported as a CDN error"; fi

# ---- 3b. Instagram rips with the Firefox login first; cookieless only as a fallback; refusals start a cooldown
if grep -q 'is_instagram' "$ENGINE" && grep -q 'ig_cooldown_set' "$ENGINE" && ! grep -q 'instagram.com/reel/\*.*COOKIES=""' "$ENGINE"; then
  pass "Instagram: login first, one cookieless fallback, cooldown after a refusal"
else fail "Instagram rule drifted (cookieless by default, or no cooldown)"; fi

# ---- 3c. livestream rewind: the hook inside the installed yt-dlp is still there
# tools/live-rewind.py moves yt-dlp's 120 h rewind cap to the asked window; it finds
# the constant by value and exits 86 when a yt-dlp update moved it (the engine then
# records from now and says so). Offline: --version through the patched wrapper.
_lpy=$(sed -n '1s/^#![ ]*//p' "$YTDLP" 2>/dev/null); case "$_lpy" in *python*) [ -x "$_lpy" ] || _lpy="" ;; *) _lpy="" ;; esac
[ -z "$_lpy" ] && command -v python3 >/dev/null 2>&1 && python3 -c 'import yt_dlp' >/dev/null 2>&1 && _lpy="$(command -v python3)"
if [ -z "$_lpy" ]; then skip "live rewind hook — no python with yt_dlp found beside $YTDLP"
elif SLIPMAT_LIVE_BACK=60 "$_lpy" "$REPO/tools/live-rewind.py" --version >/dev/null 2>"$S/rewind.err"; then pass "live rewind hook present in yt-dlp $("$YTDLP" --version 2>/dev/null) (from-start / last-Nh doors work)"
else fail "live rewind hook missing — this yt-dlp moved it; the livestream doors record from now ($(head -1 "$S/rewind.err"))" "$S/rewind.err"; fi

# ---- 3d. every mode the Shortcut builder emits is one the launcher handles -------
_lmiss=""
for _m in $(sed -n 's/^ *make_one "[^"]*" *\([a-z0-9-]*\) .*/\1/p' "$REPO/shortcuts/make-shortcuts.sh"); do
  grep -q "mode is \"$_m\"" "$REPO/shortcuts/launch.applescript" || _lmiss="$_lmiss $_m"
done
if [ -z "$_lmiss" ] && osacompile -o "$S/launch.scpt" "$REPO/shortcuts/launch.applescript" 2>/dev/null; then pass "launcher compiles and handles every builder mode"
else fail "launcher drift: modes not handled or script does not compile:$_lmiss"; fi

# ---- 4. the private embed-host list never lands in a run log ----------------
# A host may appear legitimately in a log whose own source URL is on that host;
# anywhere else it is a leak (logs get handed to people and to AI agents). Scope:
# logs written since the engine last changed — what THIS engine does.
_hosts=$( ( [ -f "$REAL_HOME/.slipmat/config" ] && . "$REAL_HOME/.slipmat/config" 2>/dev/null; printf '%s' "${SLIPMAT_EMBED_HOSTS:-}" ) 2>/dev/null )
if [ -z "$_hosts" ]; then skip "embed-host privacy sweep — no SLIPMAT_EMBED_HOSTS in your config"
else
  _leak=""; _hn=0
  for _u in $_hosts; do
    _hn=$((_hn+1)); _h=$(printf '%s' "$_u" | sed -E 's#^[a-zA-Z]+://##; s#/.*##; s#^www\.##')
    [ -n "$_h" ] || continue
    while IFS= read -r _lf; do
      [ -n "$_lf" ] || continue
      _src=$(sed -n '2p' "$_lf" | sed -E 's#^url:[[:space:]]*##; s#^[a-zA-Z]+://##; s#/.*##; s#^www\.##')
      case "$_src" in *"$_h"*) continue ;; esac
      grep -qF "$_h" "$_lf" 2>/dev/null && _leak="$_leak
    host $_hn of $(printf '%s' "$_hosts" | wc -w | tr -d ' ') in: $(basename "$_lf")"
    done <<EOF
$(find "$REAL_HOME/.slipmat/logs" -type f -name '*.log' -newer "$ENGINE" 2>/dev/null)
EOF
  done
  _nlog=$(find "$REAL_HOME/.slipmat/logs" -type f -name '*.log' -newer "$ENGINE" 2>/dev/null | wc -l | tr -d ' ')
  if [ -z "$_leak" ]; then pass "embed hosts never named in your run logs ($_nlog log$([ "$_nlog" != 1 ] && printf s) since the engine last changed)"
  else fail "embed host named in a run log whose source is elsewhere:$_leak"; fi
fi

# ---- fixtures ---------------------------------------------------------------
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc2=duration=6:size=640x360:rate=30 \
  -f lavfi -i sine=frequency=440:duration=6 -c:v libvpx-vp9 -b:v 200k -c:a libopus "$FX/clean.webm" 2>/dev/null \
  && "$FFMPEG" -hide_banner -loglevel error -y -i "$FX/clean.webm" -c copy "$FX/clean.mkv" 2>/dev/null
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc2=duration=4:size=360x640:rate=30 \
  -f lavfi -i sine=frequency=440:duration=4 -c:v libx264 -pix_fmt yuv420p -c:a aac "$FX/rot0.mp4" 2>/dev/null \
  && "$FFMPEG" -hide_banner -loglevel error -y -display_rotation 90 -i "$FX/rot0.mp4" -c copy "$FX/rotated phone.mp4" 2>/dev/null
# broken timestamps: drop ~30% of frames at random but keep the survivors' original PTS (gaps)
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc2=duration=6:size=640x360:rate=30 \
  -f lavfi -i sine=frequency=440:duration=6 -c:v libx264 -pix_fmt yuv420p -g 15 -c:a aac "$FX/cfr.mp4" 2>/dev/null \
  && "$FFMPEG" -hide_banner -loglevel error -y -i "$FX/cfr.mp4" -vf "select='gt(random(1),0.3)'" -fps_mode passthrough \
       -c:v libx264 -pix_fmt yuv420p -c:a copy "$FX/defect.mkv" 2>/dev/null
if [ -s "$FX/clean.mkv" ] && [ -s "$FX/rotated phone.mp4" ] && [ -s "$FX/defect.mkv" ]; then pass "fixtures built (clean vp9 · rotated h264 · broken-PTS)"
else fail "fixtures did not build — ffmpeg needs libvpx, libx264 and lavfi"; printf '\n%d checks · %d FAIL · %ds\n' $((PASS+FAIL)) "$FAIL" $((SECONDS-T0)); exit 1; fi
case "$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$FX/rotated phone.mp4" 2>/dev/null)" in
  *,) _rawcomma=1 ;; *) _rawcomma=0 ;; esac   # ffprobe 8 prints "h264," on this file; older ffprobe does not — informational

# ---- 5. BEST on a clean vp9 (offline hook): converts to HEVC, says nothing extra
mkdir -p "$LOGS"; : > "$S/stamp5"
HOME="$FH" SLIPMAT_LOCAL_MKV="$FX/clean.mkv" "$ENGINE" "https://example.test/clean" max best </dev/null > "$S/run5.txt" 2>&1
_rc=$?; _l5=$(newest_log); _o5=$(ls -t "$OUT"/*.mp4 2>/dev/null | head -1)
if [ "$_rc" -eq 0 ] && [ -s "$_o5" ] && [ "$(vcodec "$_o5")" = "hevc" ]; then pass "BEST on vp9: hevc mp4 produced ($(basename "$_o5"))"
else fail "BEST on vp9: exit $_rc, output: ${_o5:-none} ($(vcodec "${_o5:-/nonexistent}"))" "$S/run5.txt"; fi
if [ -n "$_l5" ] && ! grep -q 'heads-up' "$_l5"; then pass "BEST is wordless: no size heads-up on a URL rip (local files and STUDIO only)"
else fail "BEST printed a size heads-up (ruled local + STUDIO only)" "$_l5"; fi
if [ -n "$_l5" ] && comma_clean "$_l5"; then pass "probed values comma-free in the BEST log"
else fail "a probed value carries ffprobe's trailing comma (BEST log)" "$_l5"; fi

# ---- 6. BEST on broken timestamps: the detector must say DEFECT ------------
HOME="$FH" SLIPMAT_LOCAL_MKV="$FX/defect.mkv" "$ENGINE" "https://example.test/defect" max best </dev/null > "$S/run6.txt" 2>&1
_rc=$?; _l6=$(newest_log); _o6=$(ls -t "$OUT"/*.mp4 2>/dev/null | head -1)
if [ -n "$_l6" ] && grep -q 'stutter [0-9.]*% → DEFECT' "$_l6"; then pass "stutter detector flags the broken-PTS clip ($(grep -o 'stutter [0-9.]*%' "$_l6" | head -1))"
else fail "stutter detector did not flag a clip missing 30% of its frames" "$_l6"; fi
if [ "$_rc" -eq 0 ] && [ -s "$_o6" ] && [ "$_o6" != "$_o5" ] && [ "$(vcodec "$_o6")" = "hevc" ]; then pass "CFR fix re-encode produced an hevc mp4"
else fail "broken-PTS clip: exit $_rc, output: ${_o6:-none}" "$S/run6.txt"; fi

# ---- 7. unattended crop batch on the rotated clip (ffprobe 8 side-data path) --
HOME="$FH" "$REPO/slipmat" z-batch "$FX/rotated phone.mp4" </dev/null > "$S/run7.txt" 2>&1
_rc=$?
_o7=$(ls -t "$FX"/"rotated phone"*" [Z]"*.mp4 "$FX"/"rotated phone (q"*.mp4 2>/dev/null | head -1)
_l7=$(ls -t "$LOGS"/*.log 2>/dev/null | grep -v 'Z-BATCH' | head -1)
if [ "$_rc" -eq 0 ] && [ -s "$_o7" ] && [ "$(vcodec "$_o7")" = "hevc" ]; then pass "z-batch on rotated phone video: hevc output ($(basename "$_o7"))"
else fail "z-batch on rotated phone video: exit $_rc, output: ${_o7:-none}" "$S/run7.txt"; fi
if [ -n "$_l7" ] && comma_clean "$_l7" && ! grep -q 'Invalid framerate' "$_l7"; then pass "rotated clip: codec and frame rate read clean through ffprobe_csv$([ "$_rawcomma" = 1 ] && printf ' (raw ffprobe prints the trailing comma here)')"
else fail "rotated clip: a probed value carries the trailing comma or ffmpeg saw an invalid framerate" "$_l7"; fi
# stored 360x640 + rotation 90 is SHOWN as 640x360 — the engine must describe the shown frame
if [ -n "$_l7" ] && grep -q 'source: 360p ·' "$_l7"; then pass "rotation-aware dimensions: rotated clip reads as landscape 360p"
else fail "rotation-aware dimensions: expected 'source: 360p ·', got '$(grep -o 'source: [^·]*' "${_l7:-/nonexistent}" | head -1)'" "$_l7"; fi

# ---- 8. every run logged under the throwaway HOME (so nothing reached yours) --
_nl=$(ls "$LOGS"/*.log 2>/dev/null | wc -l | tr -d ' ')
if [ "${_nl:-0}" -ge 3 ]; then pass "runs stayed in the throwaway HOME ($_nl run logs there, none in yours)"
else fail "expected 3+ run logs under the throwaway HOME, found ${_nl:-0}"; fi

# ---- summary + last-green ---------------------------------------------------
_el=$((SECONDS-T0))
printf '\n%b%d checks · %d pass · %d FAIL%s · %d:%02d%b\n' "$B" $((PASS+FAIL+SKIP)) "$PASS" "$FAIL" "$([ "$SKIP" -gt 0 ] && printf ' · %d skipped' "$SKIP")" $((_el/60)) $((_el%60)) "$Z"
if [ "$FAIL" -eq 0 ]; then
  if [ -d "$REAL_HOME/.slipmat" ]; then
    printf 'ffmpeg=%s\nyt-dlp=%s\nwhen=%s\n' "${FFV:-?}" "${YTV:-?}" "$(date '+%Y-%m-%d %H:%M')" > "$REAL_HOME/.slipmat/last-green"
    printf '%blast green recorded → ~/.slipmat/last-green (slipmat doctor shows it beside the live versions)%b\n' "$D" "$Z"
  fi
fi
[ "$KEEP" = "1" ] && printf '%bscratch kept: %s%b\n' "$D" "$S" "$Z"
[ "$FAIL" -eq 0 ]
