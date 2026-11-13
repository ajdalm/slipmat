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

# ---- 2b. the private liner (liner/, its own git repo) is never staged into the public repo (10.5.26)
if [ -d "$REPO/liner" ]; then
  if git -C "$REPO" check-ignore -q liner 2>/dev/null && [ -z "$(git -C "$REPO" ls-files liner 2>/dev/null)" ]; then pass "liner/ is ignored by the public repo and nothing under it is tracked"
  else fail "liner/ is NOT fully ignored by the public repo — add 'liner/' to .gitignore and unstage anything under it"; fi
fi

# ---- 3. the keys: x stops (asked once) on every download / re-encode, ↓ steps a download down; Ctrl-C is never a printed key (10.6.26)
if grep -q 'Interrupted by user' "$ENGINE"; then pass "engine recognizes yt-dlp's 'Interrupted by user' (a hand interrupt, not a CDN error)"
else fail "engine does not recognize 'Interrupted by user' — a hand interrupt would be reported as a CDN error"; fi
if [ -f "$REPO/tools/keys.py" ] && python3 -m py_compile "$REPO/tools/keys.py" 2>"$S/keys.err" \
   && grep -q 'SLIPMAT_KEYS_ASK' "$REPO/tools/keys.py" && grep -q 'tools/keys.py" watch' "$ENGINE" \
   && grep -q 'KEY_DOWN_F" \] || dl_canceled' "$ENGINE" && grep -q '_kx=0; \[ -f "${KEY_X_F' "$ENGINE" \
   && grep -q '^  keys_start download' "$ENGINE" && grep -q '^  keys_start re-encode' "$ENGINE" && grep -q 'while it ${1}s' "$ENGINE"; then
  pass "keys: x asks once on every download and re-encode (keys_start), ↓ steps a download down (key.down), the encode reads key.x"
else fail "keys drifted: tools/keys.py (the x question), keys_start before download/encode, the key.down read in by_hand, or the key.x read at the encode is missing" "$S/keys.err"; fi
if grep -q 'chip Ctrl-C\|chip "Ctrl-C"' "$ENGINE"; then fail "a rail prints Ctrl-C as a key — Ctrl-C is the emergency exit, never a printed key (his 10.5 ruling)"
else pass "no rail prints Ctrl-C as a key (x is the stop everywhere; Ctrl-C stays the unprinted emergency exit)"; fi
# ---- 3a. asks in chip form (10.12.26): one line per question, keycap chips glued to outcomes — no [y/N] prompt anywhere
if grep -q '\[y/N\]\|\[Y/n\]' "$ENGINE" "$REPO/engine/slipmat-audio" "$REPO/tools/z-batch.sh" "$REPO/tools/hello.sh" 2>/dev/null; then
  fail "a [y/N] prompt is back — every ask is a chip line (chip_line: question, [Enter] outcome, [key] outcome)"
elif grep -q '^chip_line()' "$ENGINE" && grep -q 'chip_line "delete the original?" Enter "keep both" y "delete it"' "$ENGINE" \
     && grep -q 'chip_line "keep your pick?" Enter "Best MP4' "$ENGINE" && grep -q 'Finder\\" to delete POSIX file \\"$ORIG_OUT' "$ENGINE"; then
  pass "asks are chip lines (no [y/N] left); the delete-original ask moves the file to the Trash; Enter on a flagged custom pick takes the Best MP4"
else fail "the chip form drifted: chip_line, the delete-original Trash call, or the custom-pick ask changed"; fi

# ---- 3a2. an ENDED stream still being finished by YouTube (post_live) is a normal download, never a capture (10.13.26)
# A post_live dump lists every fragment with a known duration; the old routing "recorded" a finished show
# against a wall clock and a stop cut the seal short. Offline: a tiny post_live dump through the engine's own selector.
cat > "$S/postlive.json" <<'JEOF'
{"id":"x","title":"t","live_status":"post_live","is_live":false,"was_live":true,"duration":12143,"formats":[
 {"format_id":"140","ext":"m4a","protocol":"http_dash_segments","vcodec":"none","acodec":"mp4a.40.2","filesize":218574000,"url":"https://e/a"},
 {"format_id":"298","ext":"mp4","protocol":"http_dash_segments","vcodec":"avc1.4D4020","acodec":"none","height":720,"width":1280,"fps":60,"filesize":4005679714,"url":"https://e/v"}]}
JEOF
_vrpy=$(sed -n "/^VR_PY='/,/^'$/p" "$ENGINE" | sed '1s/^VR_PY=.//; $d' | sed "s/'\\\\''/'/g")
if grep -q '^  post_live)$' "$ENGINE" && grep -q '^got_line()' "$ENGINE" && grep -q 'got_line "$OUT"' "$ENGINE" \
   && [ "$(python3 -c "$_vrpy" hasvideo < "$S/postlive.json" 2>/dev/null)" = "1" ] \
   && python3 -c "$_vrpy" menu < "$S/postlive.json" 2>/dev/null | grep -q 'http_dash_segments'; then
  pass "ended stream (post_live): routes as a normal download of the whole replay; the receipt's got-line compares the file to the source length"
else fail "post_live routing drifted: the post_live case, got_line, or the selector on a post_live dash dump" ; fi

# ---- 3a3. parallel pieces (-N) exist ONLY inside the YouTube-replay gate (10.13.26 ruling): everywhere else the ban stands
_npar=$(grep -c -- '-N \$_npar\|-N "\$' "$ENGINE"); _nall=$(grep -c -- ' -N [0-9$]' "$ENGINE")
if [ "$_npar" -ge 1 ] && [ "$_nall" -le 1 ] && grep -q '^DLPAR=""; YT_PIECES=0' "$ENGINE" && grep -q '\$DLPAR --fragment-retries' "$ENGINE" \
   && grep -q '^pieces_backoff()' "$ENGINE" && grep -q 'while \[ "$YTRC" -ne 0 \] && pieces_backoff' "$ENGINE" && grep -q 'if pieces_backoff; then continue; fi' "$ENGINE" \
   && grep -q '^replay_holes()' "$ENGINE" && grep -q 'r_frame_rate,duration,nb_read_packets' "$ENGINE" && grep -q 'replay_holes "$DLF"' "$ENGINE" \
   && sed -n '/^pieces_fewer()/,/^}/p' "$ENGINE" | grep -q 'rm -f "$WORKDIR/${WORKSTEM}".\*'; then
  pass "parallel pieces: -N only inside the YouTube replay gate; the race backoff restarts CLEAN (never resumes); every pieces replay is frame-counted (r_frame_rate) before it is handed over"
else fail "parallel pieces drifted: -N appears outside the DLPAR gate ($_nall sites) or DLPAR is not applied to the download calls"; fi

# ---- 3a4. bot-walled pages walk the browser ladder (10.13.26, Rumble): chrome, then firefox, then safari; a page refused again at the download rotates to the next rung; a segment error never rotates
if grep -q '^IMP_LADDER="${SLIPMAT_BROWSERS:-chrome firefox safari}"' "$ENGINE" && grep -q '^imp_probe()' "$ENGINE" && grep -q '^imp_rotate()' "$ENGINE" \
   && ! grep -q -- '--impersonate firefox --no-warnings -J' "$ENGINE" \
   && [ "$(grep -c '&& imp_rotate; do' "$ENGINE")" -ge 3 ] && grep -q 'if imp_rotate; then continue; fi' "$ENGINE"; then
  eval "$(sed -n '/^imp_refused()/,/^}/p' "$ENGINE")"
  printf 'ERROR: [RumbleEmbed] v7el6ju: Unable to download JSON metadata: HTTP Error 403: Forbidden\n' > "$S/imp.page"
  printf 'ERROR: unable to download video data: HTTP Error 403: Forbidden\n' > "$S/imp.seg"
  if YTERR="$S/imp.page" imp_refused && ! YTERR="$S/imp.seg" imp_refused; then
    pass "bot-walled page: the browser ladder (chrome · firefox · safari) at the probe and again at the download; only a page-read 403 rotates"
  else fail "imp_refused drifted: the page-read 403 must match and a segment 403 must not"; fi
else fail "browser ladder drifted: IMP_LADDER/imp_probe/imp_rotate missing, a bare firefox probe is back, or the download loops no longer rotate"; fi

# ---- 3a4b. the video server hangs up on a fingerprint (11.12.26, Rumble's CDN): a curl-level close with nothing downloaded moves to the next rung; a close mid-file, a plain fetch and a segment 503 never do
if grep -q '^imp_hungup()' "$ENGINE" && sed -n '/^imp_rotate()/,/^}/p' "$ENGINE" | grep -q 'elif imp_hungup; then _iw=server' \
   && grep -q 'elif imp_hungup; then$' "$ENGINE" && grep -q 'closed the connection on every browser fingerprint tried' "$ENGINE"; then
  eval "$(sed -n '/^imp_hungup()/,/^}/p' "$ENGINE")"
  mkdir -p "$S/hung"
  printf 'ERROR: unable to download video data: Failed to perform, curl: (56) Connection closed abruptly. See https://curl.se/libcurl/c/libcurl-errors.html first for more details.\n' > "$S/hung.56"
  printf 'ERROR: unable to download video data: HTTP Error 503: Service Unavailable\n' > "$S/hung.503"
  _h1=n; _h2=n; _h3=n; _h4=n
  ( WORKDIR="$S/hung"; WORKSTEM=vr_t; IMPARGS="--impersonate chrome"; YTERR="$S/hung.56"; imp_hungup ) && _h1=y
  ( WORKDIR="$S/hung"; WORKSTEM=vr_t; IMPARGS=""; YTERR="$S/hung.56"; imp_hungup ) || _h2=y
  ( WORKDIR="$S/hung"; WORKSTEM=vr_t; IMPARGS="--impersonate chrome"; YTERR="$S/hung.503"; imp_hungup ) || _h3=y
  dd if=/dev/zero of="$S/hung/vr_t.f1.mp4.part" bs=1048576 count=2 2>/dev/null
  ( WORKDIR="$S/hung"; WORKSTEM=vr_t; IMPARGS="--impersonate chrome"; YTERR="$S/hung.56"; imp_hungup ) || _h4=y
  if [ "$_h1$_h2$_h3$_h4" = "yyyy" ]; then
    pass "fingerprint hung up on: a curl close with nothing downloaded rotates the ladder; a plain fetch, a segment 503 and a close with 2 MB in hand do not; a spent ladder dies by name"
  else fail "imp_hungup drifted (empty+fingerprint=$_h1 plain=$_h2 segment503=$_h3 midfile=$_h4; all must be y)"; fi
else fail "fingerprint hang-up drifted: imp_hungup missing, imp_rotate no longer asks it, or the spent-ladder death line is gone"; fi

# ---- 3a5. a sniffer's rendition playlist (10.13.26, Newsmax): the master beside it is tried first (item id, then playlist/master/index); a .m3u8 link is never a photo post
eval "$(sed -n '/^hls_master_candidates()/,/^}/p' "$ENGINE")"
_c1=$(hls_master_candidates 'https://nmxvod24.akamaized.net/hls/account=ab0NPfBJhS8g/item=j5BssrTT1S8E/version=202610090202_7/v2.0-j5BssrTT1S8E-hls-202610090202_7-audio_eng=128000.m3u8' | head -1)
_c2=$(hls_master_candidates 'https://cdn.example/x/playlist.m3u8?k=1' | head -1)
if [ "$_c1" = 'https://nmxvod24.akamaized.net/hls/account=ab0NPfBJhS8g/item=j5BssrTT1S8E/version=202610090202_7/j5BssrTT1S8E.m3u8' ] \
   && [ "$_c2" = 'https://cdn.example/x/master.m3u8?k=1' ] && grep -q '^hls_master_hunt()' "$ENGINE" && grep -q '|| hls_master_hunt ' "$ENGINE" \
   && grep -q 'audio-only half of the stream' "$ENGINE"; then
  pass "rendition playlist: the master beside it is tried (item id first), a .m3u8 link is never a photo post, an audio-only half without a master is said so"
else fail "rendition-playlist rule drifted (candidates: '$_c1' / '$_c2')"; fi

# ---- 3a6. a Newsmax show page rips as is (10.13.26): the episode id → Newsmax's own service → the master playlist; the title names the show (a menu row) and the air date without the naming window
eval "$(sed -n '/^lc()/p; /^nmx_page_id()/,/^}/p; /^nmx_title_date()/,/^}/p; /^nmx_show_match()/,/^}/p' "$ENGINE")"
_rows='HIGBIE|SCHMITT|GREG KELLY|FINNERTY'
if [ "$(nmx_page_id 'https://www.newsmaxtv.com/Shows/Carl-Higbie-Frontline/vid/1ad3b1e0-c375-11f1-945f-9197c3698885')" = "1ad3b1e0-c375-11f1-945f-9197c3698885" ] \
   && [ -z "$(nmx_page_id 'https://rumble.com/v7grjhc-x.html')" ] \
   && [ "$(nmx_title_date 'Carl Higbie Frontline (10/08/26)')" = "10.8.26" ] && [ -z "$(nmx_title_date 'no date')" ] \
   && [ "$(nmx_show_match 'Greg Kelly Reports (10/08/26)' "$_rows")" = "GREG KELLY" ] && [ -z "$(nmx_show_match 'Wake Up America (10/08/26)' "$_rows")" ] \
   && grep -q '^nmx_page_hunt()' "$ENGINE" && grep -q '^  nmx_page_hunt ' "$ENGINE" && grep -q '\[ "$NMX_NAMED" != "1" \]' "$ENGINE" && grep -q 'the page says:' "$ENGINE" \
   && grep -q '^nmx_show_hunt()' "$ENGINE" && grep -q '^  nmx_show_hunt ' "$ENGINE" && grep -q 'WHICH EPISODE?' "$ENGINE" && grep -q 'the stream answers anyway' "$ENGINE" && ! grep -q 'behind the Newsmax+ login' "$ENGINE"; then
  pass "Newsmax: a SHOW page lists its episodes (Enter = newest); an episode page → vodservice → master; the title names the show row + air date, the naming window stays shut when it can; a Newsmax+ badge never blocks"
else fail "Newsmax show-page rule drifted (id/date/row matchers or the hooks)"; fi

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
# ---- 3c2. a from-now live capture pairs HLS-only audio (11.2.26)
# YouTube's live audio arrives as an HLS rendition (ext mp4, codec unstated) beside
# video-only avc1 playlists; a pairing that insists on m4a matches nothing and the
# capture dies with "Requested format is not available" before a byte lands.
if grep -q 'LIVE_F="bv\*\[ext=mp4\]\[vcodec^=avc1\]${_lc}+ba\[ext=m4a\]/bv\*\[ext=mp4\]\[vcodec^=avc1\]${_lc}+ba/' "$ENGINE"; then
  pass "live capture selector falls back to HLS-only audio (+ba without the m4a gate)"
else fail "live capture selector insists on m4a audio — a from-now YouTube capture dies with 'Requested format is not available'"; fi
# a picked row caps every fallback rung: the rewind's format list carries other ids than the
# picker's dump, the exact id misses, and an uncapped fallback took 1080 on a 360p pick (11.2.26)
if grep -q '_lc="\[height<=\$_ph\]"' "$ENGINE" && grep -q 'LIVE_F="${SEL}/${LIVE_F}"' "$ENGINE"; then
  pass "a picked live row caps every fallback rung by its height (a 360p pick on a rewind stays ≤360)"
else fail "a picked live row leads an UNCAPPED fallback — when the rewind's ids differ, a 360p pick comes back 1080"; fi
# … and the ladder never ENDS in the cap (11.2.26): when nothing at or under the picked
# height is offered, the same pairs run uncapped — a capture lands at what there is.
# Functional: yt-dlp's own selector on a stream offering only 1080 video + audio.
if [ "$(grep -c 'best${_lc}/bv\*\[ext=mp4\]\[vcodec^=avc1\]+ba/bv\*+ba/best"' "$ENGINE")" != "2" ] || ! grep -q '^live_receipt_notes() {' "$ENGINE"; then
  fail "the live ladder ends in its cap — a 360p pick on a stream offering only 1080 dies with 'Requested format is not available'"
elif [ -n "$_lpy" ]; then
  _lad=$(sed -n 's/^ *LIVE_F="\(bv\*.*\)"$/\1/p' "$ENGINE" | head -1); _lad=${_lad//'${_lc}'/[height<=360]}
  _land=$("$_lpy" - "$_lad" <<'PY' 2>&1
import sys, yt_dlp
fmts = [{'format_id': '137', 'ext': 'mp4', 'vcodec': 'avc1.640028', 'acodec': 'none', 'height': 1080, 'url': 'x', 'protocol': 'http_dash_segments'},
        {'format_id': '140', 'ext': 'm4a', 'vcodec': 'none', 'acodec': 'mp4a.40.2', 'url': 'x', 'protocol': 'http_dash_segments'}]
sel = yt_dlp.YoutubeDL({'quiet': True}).build_format_selector(sys.argv[1])
print('+'.join(f['format_id'] for f in sel({'formats': fmts, 'has_merged_format': False, 'incomplete_formats': False})) or 'nothing')
PY
)
  if [ "$_land" = "137+140" ]; then pass "a 360p pick on a stream offering only 1080 still lands (137+140) — the ladder never ends in its cap"
  else fail "the capped live ladder selects '$_land' when only 1080 is offered (want 137+140)"; fi
else skip "live ladder tail — no python with yt_dlp"; fi
# ---- 3c3. a merge that dies after a whole download is merged here, never fetched again (11.2.26)
# yt-dlp's own merge failed three times in one night on hours-long replays; the
# blank-page swap then re-downloaded each from the top. The scratch halves are
# whole: the engine merges them itself. Functional: two halves + yt-dlp's words in.
_salv=$(sed -n '/^  salvage_merge() {$/,/^  }$/p' "$ENGINE")
if [ -z "$_salv" ] || ! grep -q 'if salvage_merge; then YTRC=0' "$ENGINE"; then
  fail "no salvage merge — a merge that dies after a whole download walks the ladder and fetches hours of video again"
elif ! grep -q 'ls "\$WORKDIR/\${WORKSTEM}"\.\* 2>/dev/null)" \]; then' "$ENGINE"; then
  fail "the blank-page manifest swap still keys on 'no .part' — it fires on a failed merge and re-downloads the whole show"
else
  mkdir -p "$S/salv"
  "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=3:size=320x240:rate=30 -c:v libx264 -pix_fmt yuv420p -an "$S/salv/x.f1.mp4" </dev/null 2>/dev/null
  "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i sine=duration=3 -c:a aac -vn "$S/salv/x.f2.m4a" </dev/null 2>/dev/null
  printf 'ERROR: Postprocessing: Conversion failed!\n' > "$S/salv/ytdlp.err"
  _rc=$( ( WORKDIR="$S/salv"; WORKSTEM="x"; YTERR="$S/salv/ytdlp.err"; RUNLOG="$S/salv/run.log"; RETRY_NOTE=""
           yterr_show() { :; }; warn() { :; }; logln() { :; }
           eval "$_salv"; salvage_merge >/dev/null 2>&1; echo $? ) 2>/dev/null )
  _vs=$("$FFPROBE" -v error -show_entries stream=codec_type -of csv=p=0 "$S/salv/x.mkv" 2>/dev/null | tr -d ',' | sort -u | tr '\n' ' ')
  if [ "$_rc" = "0" ] && [ "$_vs" = "audio video " ] && [ ! -e "$S/salv/x.f1.mp4" ] && [ ! -e "$S/salv/x.f2.m4a" ]; then
    pass "a failed yt-dlp merge is merged here: two whole halves → one mkv with both streams, nothing fetched again"
  else fail "salvage merge did not produce one mkv from two whole halves (rc=$_rc · streams='$_vs')" "$S/salv/run.log"; fi
  : > "$S/salv/ytdlp.err"
  _rc2=$( ( WORKDIR="$S/salv"; WORKSTEM="x"; YTERR="$S/salv/ytdlp.err"; RUNLOG="$S/salv/run.log"; RETRY_NOTE=""
            yterr_show() { :; }; warn() { :; }; logln() { :; }
            eval "$_salv"; salvage_merge >/dev/null 2>&1; echo $? ) 2>/dev/null )
  if [ "$_rc2" != "0" ]; then pass "salvage merge stays out of every other failure (no 'Postprocessing' in yt-dlp's words → not its case)"
  else fail "salvage merge fired on a failure that was not yt-dlp's merge"; fi
fi

# ---- 3c4. an unverified rendition never wins a size (11.2.26, the El-Sayed interview): yt-dlp 2026.10.26 lists
# YouTube's HLS copy of every DASH size (Untested in -F, ranked last by yt-dlp itself); picked by bitrate it won
# every rung and its MPEG-TS half killed the merge at 720, 480 and 360 in a row. The whole file wins its size, the
# unverified copy is last — with or without the flag (the day yt-dlp verifies them, a whole file still wins).
cat > "$S/hlscopy.json" <<'JEOF'
{"id":"x","title":"t","duration":3931,"formats":[
 {"format_id":"140","ext":"m4a","protocol":"https","vcodec":"none","acodec":"mp4a.40.2","tbr":129.5,"filesize":63622247,"url":"https://e/a"},
 {"format_id":"134","ext":"mp4","protocol":"https","vcodec":"avc1.4D401E","acodec":"none","height":360,"width":640,"fps":30,"tbr":198.5,"filesize":93020000,"url":"https://e/v"},
 {"format_id":"230","ext":"mp4","protocol":"m3u8_native","vcodec":"avc1.4D401E","acodec":"none","height":360,"width":640,"fps":30,"tbr":442.5,"__needs_testing":true,"url":"https://e/m.m3u8"},
 {"format_id":"136","ext":"mp4","protocol":"https","vcodec":"avc1.64001F","acodec":"none","height":720,"width":1280,"fps":30,"tbr":630.4,"filesize":295440000,"url":"https://e/v7"},
 {"format_id":"232","ext":"mp4","protocol":"m3u8_native","vcodec":"avc1.64001F","acodec":"none","height":720,"width":1280,"fps":30,"tbr":1152.1,"__needs_testing":true,"url":"https://e/m7.m3u8"}]}
JEOF
sed 's/,"__needs_testing":true//g' "$S/hlscopy.json" > "$S/hlscopy-verified.json"
_us=$(printf '\037')
_s3=$(python3 -c "$_vrpy" select 360 < "$S/hlscopy.json" 2>/dev/null | cut -d"$_us" -f1,4)
_s7=$(python3 -c "$_vrpy" select 720 < "$S/hlscopy.json" 2>/dev/null | cut -d"$_us" -f1,4)
_sv=$(python3 -c "$_vrpy" select 720 < "$S/hlscopy-verified.json" 2>/dev/null | cut -d"$_us" -f1,4)
_mn=$(python3 -c "$_vrpy" menu < "$S/hlscopy.json" 2>/dev/null | cut -d"$_us" -f1,6,7 | tr '\n' ' ')
if [ "$_s3" = "134+140${_us}https" ] && [ "$_s7" = "136+140${_us}https" ] && [ "$_sv" = "136+140${_us}https" ] \
   && [ "$_mn" = "720${_us}https${_us}136+140 360${_us}https${_us}134+140 " ]; then
  pass "a size's whole file beats its unverified HLS copy (yt-dlp 2026.10.26 lists both): 360 → 134+140, 720 → 136+140, the menu rows too, flag or no flag"
else fail "the picker takes an HLS copy over the whole file at the same size (360: '$_s3' · 720: '$_s7' · verified: '$_sv' · menu: '$_mn')"; fi

# ---- 3c5. the salvage merge takes a video half whose packets carry no timestamps (11.2.26): matroska refuses
# the packet, mp4 stamps it — so the salvage goes by way of an mp4. Functional on the real 600 KB MPEG-TS snippet
# kept at ~/.slipmat/fixtures/yt-hls-untimed.ts when it is there (25 s of the El-Sayed half); the route's presence otherwise.
_unt="$REAL_HOME/.slipmat/fixtures/yt-hls-untimed.ts"
if ! printf '%s\n' "$_salv" | grep -q 'salvage\.mp4'; then
  fail "the salvage merge has no mp4 route — a video half with no timestamps dies in the mkv (El-Sayed, 11.2.26)"
elif [ -s "$_unt" ]; then
  mkdir -p "$S/salv2"; cp "$_unt" "$S/salv2/y.f230.mp4"
  "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i sine=duration=25 -c:a aac -vn "$S/salv2/y.f140.m4a" </dev/null 2>/dev/null
  printf 'ERROR: Postprocessing: Conversion failed!\n' > "$S/salv2/ytdlp.err"
  _rc=$( ( WORKDIR="$S/salv2"; WORKSTEM="y"; YTERR="$S/salv2/ytdlp.err"; RUNLOG="$S/salv2/run.log"; RETRY_NOTE=""
           yterr_show() { :; }; warn() { :; }; logln() { :; }
           eval "$_salv"; salvage_merge >/dev/null 2>&1; echo $? ) 2>/dev/null )
  _d=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$S/salv2/y.mkv" 2>/dev/null | cut -d. -f1)
  _vs=$("$FFPROBE" -v error -show_entries stream=codec_type -of csv=p=0 "$S/salv2/y.mkv" 2>/dev/null | tr -d ',' | sort -u | tr '\n' ' ')
  if [ "$_rc" = "0" ] && [ "$_vs" = "audio video " ] && [ "${_d:-0}" -ge 24 ] && grep -q 'by way of an mp4' "$S/salv2/run.log" && [ ! -e "$S/salv2/y.salvage.mp4" ]; then
    pass "salvage by way of an mp4: the real MPEG-TS half with no timestamps lands in one mkv (${_d}s, both streams), the mp4 step cleaned up"
  else fail "salvage by way of an mp4 failed on the timestamp-less half (rc=$_rc · streams='$_vs' · ${_d:-0}s)" "$S/salv2/run.log"; fi
else skip "salvage by way of an mp4 — the route is present; no ~/.slipmat/fixtures/yt-hls-untimed.ts on this machine to run it on"; fi
# ---- 3c4b. a rewind says how far each stream is behind live (11.2.26)
# the driver wraps yt-dlp's fragment generator and writes "video <s>" / "audio <s>";
# the REC line reads it. Functional: a fake generator under the real wrapper.
if [ -n "$_lpy" ]; then
  _lagout=$(SLIPMAT_LIVE_LAG="$S/live.lag" "$_lpy" - "$REPO/tools/live-rewind.py" <<'PY' 2>&1
import os, sys, runpy
from yt_dlp.extractor.youtube import YoutubeIE
def fake(self, video_id, itag, client_name, live_start_time, url_feed, base_url, fragment_duration, last_seq_cache, ctx):
    for idx in range(100, 104):
        yield {'url': f'https://h/x?sq={idx}', 'fragment_count': 1000}
YoutubeIE._live_adaptive_fragments = fake
sys.argv = [sys.argv[1], '--version']
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit:
    pass
list(YoutubeIE._live_adaptive_fragments(None, 'v', 137, 'web', None, None, None, 5, {}, {}))
list(YoutubeIE._live_adaptive_fragments(None, 'v', 140, 'web', None, None, None, 5, {}, {}))
print(open(os.environ['SLIPMAT_LIVE_LAG']).read().replace('\n', ' '))
PY
)
  if printf '%s' "$_lagout" | grep -q 'audio 4480 -1 video 4480 -1' && grep -q 'SLIPMAT_LIVE_LAG="\$LIVE_LAG"' "$ENGINE" \
     && grep -q '_l2="video $_lv behind live$_ev · audio is live · stop now = video ends $_lv early"' "$ENGINE" && grep -q '^lag_clock() {' "$ENGINE" && grep -q '^eta_words() {' "$ENGINE" && grep -q '_gap=$(( LIVE_LAG_V - LIVE_LAG_A ))' "$ENGINE" && grep -q '^read_live_lag() {' "$ENGINE"; then
    pass "a rewind writes how far each stream is behind live (fragment 103 of a 1000-head at 5 s = 4480 s, eta unknown yet) and its own line under REC reads it; the receipt reads the gap"
  else fail "the rewind lag file or its REC-line reader is missing (driver said: $(printf '%s' "$_lagout" | tail -1))"; fi
else skip "rewind lag — no python with yt_dlp"; fi
# ---- 3c5. the live seal is an mp4 (11.2.26)
# A split-playlist capture (video + audio read by one ffmpeg) lands as MPEG-TS under an
# .mp4 name and yt-dlp does not fix a merged live download; QuickTime refused it.
_sealfn=$(sed -n '/^seal_as_mp4() {$/,/^}$/p' "$ENGINE")
if [ -z "$_sealfn" ] || ! grep -q '^  seal_as_mp4 ' "$ENGINE"; then
  fail "no seal_as_mp4 — a from-now capture of split playlists stays MPEG-TS under an .mp4 name (QuickTime refuses it)"
else
  mkdir -p "$S/seal"
  "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=2:size=320x240:rate=30 -f lavfi -i sine=duration=2 -c:v libx264 -pix_fmt yuv420p -c:a aac -f mpegts "$S/seal/cap.mp4" </dev/null 2>/dev/null
  _after=$( ( PRODUCED="$S/seal/cap.mp4"; LIVE_ERRLOG="$S/seal/err.log"; C_GRN=""; G_OK=""; C_RESET=""
              live_line() { :; }; live_line_end() { :; }; warn() { :; }; logln() { :; }
              eval "$_sealfn"; seal_as_mp4 >/dev/null 2>&1; printf '%s' "$PRODUCED" ) 2>/dev/null )
  _afmt=$("$FFPROBE" -v error -show_entries format=format_name -of csv=p=0 "$_after" 2>/dev/null | tr -d ',')
  _ast=$("$FFPROBE" -v error -show_entries stream=codec_type -of csv=p=0 "$_after" 2>/dev/null | tr -d ',' | sort -u | tr '\n' ' ')
  if [ "$_after" = "$S/seal/cap.mp4" ] && case "$_afmt" in *mp4*) true ;; *) false ;; esac && [ "$_ast" = "audio video " ] && [ ! -e "$S/seal/cap.remux.tmp" ]; then
    pass "live seal: an MPEG-TS capture is remuxed into a real mp4 under its own name (both streams, no temp left)"
  else fail "live seal did not turn the MPEG-TS capture into an mp4 (name='$_after' format='$_afmt' streams='$_ast')" "$S/seal/err.log"; fi
fi
# 10.5.26 eve, seen in the field: a second Ctrl-C mid-seal left NAME.f136.mp4 + NAME.f140.mp4.part and the
# receipt named the silent video half ("captured 43:08:09"). The wrapper disarms the key after the first
# press; the engine never picks a per-stream intermediate and re-arms the key afterwards.
if grep -q 'VINTR' "$REPO/tools/live-rewind.py" && grep -q 'SLIPMAT_LIVE_STOP' "$REPO/tools/live-rewind.py"; then pass "live: the first Ctrl-C disarms the key (live-rewind.py handles SIGINT, flags the REC line)"
else fail "live: live-rewind.py lost its SIGINT handler (a second Ctrl-C would abort the seal)"; fi
if grep -q 'f\[0-9\]+\\.\[^.\]+\$' "$ENGINE" && grep -q "stty intr '\^C'" "$ENGINE" && grep -q '^seal_live_orphans()' "$ENGINE"; then pass "live: receipts skip .fNNN halves, orphans get sealed, Ctrl-C is re-armed"
else fail "live: PRODUCED filter / orphan sealer / stty re-arm drifted"; fi
if grep -q '^ask_live_start()' "$ENGINE" && grep -q 'SLIPMAT_Z_AUTO:-0}" != "1" ] && \[ "${SLIPMAT_LIVE_ASK' "$ENGINE"; then pass "live: the start ask exists and stays out of z-auto batches"
else fail "live: the start ask or its z-auto guard is missing"; fi
if grep -q 'SLIPMAT_LIVE_ASK_FLAG' "$REPO/tools/live-rewind.py" && grep -q '_restore_mode' "$REPO/tools/live-rewind.py" \
   && grep -q 'def live_thread' "$REPO/tools/keys.py" && grep -q 'while it records' "$ENGINE" && grep -q 'LIVE_ASK_TEXT=' "$ENGINE"; then
  pass "live keys: x asks once then takes the first-Ctrl-C seal path; the terminal mode is restored at exit; the keys are shown"
else fail "live keys drifted: the x thread (keys.py / live-rewind.py), its exit-time terminal restore, or the 'while it records' rail is missing"; fi

# ---- 3c2. finished windows close themselves; the output folder only gains finished files (10.29.26)
# the launcher arms its URL windows (SLIPMAT_WINDOW=1) and never the batch window;
# every live yt-dlp call writes under the in-progress folder; the close helper is a
# no-op off a tty and carries the three-line copy (x or Enter close now, any other key keeps)
_la="$REPO/shortcuts/launch.applescript"
if grep -q 'do script "SLIPMAT_WINDOW=1 " & cmd' "$_la" && ! grep -q 'SLIPMAT_WINDOW=1.*z-batch' "$_la" \
   && [ "$(grep -c -- '-o "\$CAPDIR/\${NAME_TMPL}\.%(ext)s"' "$ENGINE")" = "3" ] && ! grep -q -- '-o "\$OUTDIR/\${NAME_TMPL}' "$ENGINE" \
   && grep -q 'window_close "\$_rc"' "$ENGINE" && grep -q 'window-close.sh' "$REPO/engine/slipmat-audio" "$REPO/engine/slipmat-spotify" \
   && [ "$(echo | TERM_PROGRAM=none bash "$REPO/tools/window-close.sh" 1 2>&1 | wc -c | tr -d ' ')" = "0" ] \
   && grep -q 'close now' "$REPO/tools/window-close.sh" && grep -q 'keep open' "$REPO/tools/window-close.sh" \
   && grep -q "x|X|'') " "$REPO/tools/window-close.sh"; then
  pass "finished windows close themselves (launcher-armed only, batch never; x/Enter close now, any other key keeps); live captures write under the in-progress folder; the helper is silent off a tty"
else fail "window close wiring: launcher arm, the three live -o paths, the exit hook, audio+spotify hooks, the helper's no-tty silence, or its three-line copy"; fi

# ---- 3c3. nothing growing ever touches the output folder (10.29.26) ---------
# every finished file goes through place_final (fast path, re-encode, remux, live);
# the name reservation is a .mp4.claim in $CAPDIR; the folder is permanent (no rmdir);
# nothing is ever mv'd straight onto $OUT; the live seal writes in $CAPDIR
if [ "$(grep -c 'place_final "' "$ENGINE")" = "4" ] && grep -q '^place_final() {' "$ENGINE" \
   && grep -q 'set -C; : > "\${CAPDIR:-\$OUTDIR}/\${_try}.mp4.claim"' "$ENGINE" \
   && ! grep -q 'rmdir "\$CAPDIR"' "$ENGINE" && ! grep -qE 'mv (-f )?"\$(_FT|ENC_TMP)" "\$OUT"' "$ENGINE" \
   && [ "$(grep -c -- '-movflags +faststart "\$CAP" </dev/null' "$ENGINE")" = "2" ] \
   && grep -q 'CAPDIR="\$OUTDIR/_in progress"; mkdir -p "\$CAPDIR"' "$ENGINE"; then
  pass "the output folder only gains finished files: 4 place_final callers, .mp4.claim reservations in the permanent in-progress folder, the live seal writes there"
else fail "in-progress folder wiring: place_final callers (fast/encode/remux/live), the .mp4.claim reservation, a leftover rmdir or direct mv onto \$OUT, or the seal target"; fi

# ---- 3c4. every live status line goes through live_line (10.29.26) -----------
# a line wider than the window wraps and the redraw leaves a row behind each tick;
# live_line measures and cuts. Raw in-place draws are allowed only inside live_line
# itself and the one finished "timer landed" line; the stop sentence is said once
# (the key thread on x x, the signal handler only on Ctrl-C) as a finished line
_raw=$(grep -nE "printf '\\\\r\\\\033\\[(2)?K" "$ENGINE" | grep -vE '_ll_ind|live_line|the timer landed' | wc -l | tr -d ' ')
if grep -q '^live_line() {' "$ENGINE" && [ "$(grep -c 'live_line "' "$ENGINE")" -ge 6 ] && [ "$_raw" = "0" ] \
   && grep -q "_stop.how != 'x'" "$REPO/tools/live-rewind.py" && grep -qF "C_RESET\"\$'\\n' \"\$LIVE_PY\"" "$ENGINE" \
   && grep -q 'live_line "${C_GRN}${G_OK}${C_RESET} sealing' "$ENGINE"; then
  pass "every live status line is one in-place line cut to the window (live_line); the stop sentence is said once and the seal shows its own clock"
else fail "status lines: a raw in-place printf outside live_line ($_raw), the live_line callers, the once-only stop sentence, or the sealing clock"; fi

# ---- 3d. every mode the Shortcut builder emits is one the launcher handles -------
_lmiss=""
for _m in $(sed -n 's/^ *make_one "[^"]*" *\([a-z0-9-]*\) .*/\1/p' "$REPO/shortcuts/make-shortcuts.sh"); do
  grep -q "mode is \"$_m\"" "$REPO/shortcuts/launch.applescript" || _lmiss="$_lmiss $_m"
done
if [ -z "$_lmiss" ] && osacompile -o "$S/launch.scpt" "$REPO/shortcuts/launch.applescript" 2>/dev/null; then pass "launcher compiles and handles every builder mode"
else fail "launcher drift: modes not handled or script does not compile:$_lmiss"; fi

# ---- 3e. the day's Newsmax shows (11.2.26; the words on the line 11.12.26): the answers line, each answer's
# engine words, and the wrapper knows the verb. One answer = every show; commas or spaces; a short line =
# the usual for the rest; more answers than rows is refused; `high` = native 1080 at NMX_HIGH_Q, `h55` at
# that dial, `quick` = 480 direct, 1080 = high (a plain 1080 rip of this source lands at 720). The line is
# read whole before anything else: words in any order, and a word that is no day, no switch and no answer
# is an error, never a pick.
_nt="$REPO/tools/newsmax-today.sh"
_pl() { bash "$_nt" --parse-line "$1" | tr '\t' '|'; }
_p1=$(bash "$_nt" --parse-picks "b h q q" 4); _p2=$(bash "$_nt" --parse-picks "h" 4); _p3=$(bash "$_nt" --parse-picks "h55,480" 4); _p4=$(bash "$_nt" --parse-picks "" 2); _p5=$(bash "$_nt" --parse-picks "1080 720" 2); _p6=$(bash "$_nt" --parse-picks "b h q" 2)
_c1=$(NMX_HIGH_Q=50 bash "$_nt" --answer-cmd high); _c2=$(bash "$_nt" --answer-cmd high@55); _c3=$(bash "$_nt" --answer-cmd quick); _c4=$(bash "$_nt" --answer-cmd 720); _c5=$(bash "$_nt" --answer-cmd small)
if [ "$_p1" = "best high quick quick " ] && [ "$_p2" = "high high high high " ] && [ "$_p3" = "high@55 480 u u " ] && [ "$_p4" = "u u " ] && [ "$_p5" = "high 720 " ] && [ "$_p6" = "!many 3" ] \
   && [ "$_c1" = "SLIPMAT_KEEP_NATIVE=1 SLIPMAT_Q=50 best" ] && [ "$_c2" = "SLIPMAT_KEEP_NATIVE=1 SLIPMAT_Q=55 best" ] && [ "$_c3" = "480 auto" ] && [ "$_c4" = "720 auto" ] && [ "$_c5" = "360 auto" ] \
   && grep -q '^  newsmax)' "$REPO/slipmat" && grep -q 'SLIPMAT_KEEP_NATIVE' "$ENGINE" \
   && [ "$(_pl 'yesterday h b')" = "ok|go|-|-|yesterday|-|0|h b" ] && [ "$(_pl 'b h q q')" = "ok|go|-|-|-|-|0|b h q q" ] \
   && [ "$(_pl 'back 5 2h 3')" = "ok|go|-|-|back|5|0|2h 3" ] && [ "$(_pl 'c')" = "ok|go|-|-|back|7|0|" ] && [ "$(_pl 'both')" = "ok|go|-|-|both|-|0|" ] \
   && [ "$(_pl 'h b TODAY --here --wait 2 again')" = "ok|go|here|2|today|-|1|h b" ] && [ "$(_pl 'b now')" = "ok|go|-|0|-|-|0|b" ] && [ "$(_pl 'list')" = "ok|list|-|-|-|-|0|" ] \
   && [ "$(_pl '--help' | cut -d'|' -f1,2)" = "ok|help" ] && [ "$(_pl 'today -h' | cut -d'|' -f1,2)" = "ok|help" ] && [ "$(_pl 'help' | cut -d'|' -f1,2)" = "ok|help" ] \
   && [ "$(_pl '--hlep' | cut -d'|' -f1)" = "err" ] && [ "$(_pl 'lsit' | cut -d'|' -f1)" = "err" ] && [ "$(_pl 'today 1 2' | cut -d'|' -f1)" = "err" ] && [ "$(_pl 'back 3 h' | cut -d'|' -f1)" = "err" ] \
   && [ "$(_pl 'today yesterday' | cut -d'|' -f1)" = "err" ] && [ "$(_pl 'today --wait' | cut -d'|' -f1)" = "err" ] && [ "$(_pl 'b --wait 1080' | cut -d'|' -f1)" = "err" ] && [ "$(_pl 'today *' | cut -d'|' -f1)" = "err" ] \
   && grep -q 'mp4.claim' "$_nt" && grep -q 'due_rule' "$_nt" \
   && [ "$(bash "$_nt" --due 5 816 12345 1018 3)" = "0" ] && [ "$(bash "$_nt" --due 5 900 12345 1018 3)" = "1" ] && [ "$(bash "$_nt" --due 3 1140 12345 1198 3)" = "1" ] \
   && [ "$(bash "$_nt" --due 6 1140 12345 1018 3)" = "0" ] && [ "$(bash "$_nt" --due 5 1100 12345 1018 0)" = "0" ] && [ "$(bash "$_nt" --due 5 400 '' '' 3)" = "0" ] \
   && [ "$(bash "$_nt" --custom-picks '2h 5 8-9q' 10)" = "- high - - u - - quick quick -" ] && [ "$(bash "$_nt" --custom-picks 'all h' 3)" = "high high high" ] && [ "$(bash "$_nt" --custom-picks '' 3)" = "- - -" ] \
   && [ "$(bash "$_nt" --custom-picks '99 3' 4)" = "- - u -" ] && [ "$(bash "$_nt" --custom-picks '2:480' 3)" = "- 480 -" ]; then
  pass "slipmat newsmax: 'b h q q' → one answer per show, 'h' covers every show, a short line leaves the rest at the usual, more answers than rows is refused, 1080 = high = native at the dial; the line is read whole (words in any order: day · --here · --wait 2 · now · again · list · help) and a word it does not know (--hlep, lsit, a row number without back N, two days, --wait without hours) is an error, never a pick; a running rip's reservation counts as taken; today's episode is due only on the show's own weekdays when its usual posting time fits inside the watch; custom picks read '2h 5 8-9q' / '2:480' / 'all h' / nothing"
else fail "slipmat newsmax parsing: '$_p1' / '$_p2' / '$_p3' / '$_p4' / '$_p5' / '$_p6' · cmds '$_c1' / '$_c2' / '$_c3' / '$_c4' / '$_c5' · line '$(_pl 'h b TODAY --here --wait 2 again')' / '$(_pl '--hlep')'"; fi

# ---- 3e2. the Newsmax command end to end, offline (11.12.26): a copy of the tool beside a stand-in engine that
# only writes down how it was called, a throwaway HOME, and two shows' episode lists written here with today's
# dates (NMX_LISTS_DIR is read in place of the site). The rule that broke in the field: `--help` was read as a
# pick and started every show's rip. Asking for help, or a word the command does not know, must start nothing.
_nx="$S/nmx"; _nh="$S/nmxhome"; _nlog="$S/nmx-calls.log"
mkdir -p "$_nx/tools" "$_nx/engine" "$_nx/lists" "$_nh/.slipmat" "$_nh/out/_in progress"
cp "$_nt" "$_nx/tools/newsmax-today.sh"
printf '#!/bin/bash\nprintf "%%s|%%s|%%s\\n" "${SLIPMAT_KEEP_NATIVE:-}" "${SLIPMAT_Q:-}" "$*" >> "$NMX_TEST_LOG"\nexit 0\n' > "$_nx/engine/slipmat-video"; chmod +x "$_nx/engine/slipmat-video"
printf 'OUTDIR="%s"\nNMX_SHOWS="SHOW ONE|SHOW TWO"\nNMX_DAILY="Show-One=best|Show-Two=quick"\nNMX_HIGH_Q=45\n' "$_nh/out" > "$_nh/.slipmat/config"
python3 - "$_nx/lists" <<'NMXPY'
import json,sys,datetime,time
d=sys.argv[1]; today=datetime.date.today()
def mk(name,label,first):
    items=[]
    for k in range(first, first+5):
        day=today-datetime.timedelta(days=k)
        t=datetime.datetime(day.year,day.month,day.day,17,0)
        items.append({"id":"%s-%d"%(name.lower(),k),"label":"%s (%d/%02d/%02d)"%(label,day.month,day.day,day.year%100),"createdAt":int(time.mktime(t.timetuple())),"isHidden":False})
    json.dump(json.dumps({"items":items}), open("%s/%s.json"%(d,name),"w"))
mk("Show-One","Show One",0)   # posted today
mk("Show-Two","Show Two",1)   # newest is yesterday's
NMXPY
_nrun() { HOME="$_nh" NMX_TEST_LOG="$_nlog" NMX_LISTS_DIR="$_nx/lists" NMX_WINDOWS=0 bash "$_nx/tools/newsmax-today.sh" "$@" </dev/null > "$S/nmx-out.txt" 2>&1; }
: > "$_nlog"
_nrun --help; _h1=$?; _h1n=$(wc -l < "$_nlog" | tr -d ' '); grep -q 'slipmat newsmax help' "$S/nmx-out.txt" && _h1u=1 || _h1u=0
_nrun --hlep; _h2=$?; _nrun today 1 2; _h3=$?; _nrun today b h q; _h4=$?; _nrun back 2; _h5=$?; _h5n=$(wc -l < "$_nlog" | tr -d ' ')
_nrun today now; _g1=$?; _g1l=$(cat "$_nlog")
_nrun today now; _g2n=$(wc -l < "$_nlog" | tr -d ' '); grep -q 'started a moment ago\|ripping now' "$S/nmx-out.txt" && _g2w=1 || _g2w=0
: > "$_nlog"; _nrun h yesterday; _g3l=$(tr '\n' ';' < "$_nlog")
if [ "$_h1" = "0" ] && [ "$_h1n" = "0" ] && [ "$_h1u" = "1" ] && [ "$_h2" = "2" ] && [ "$_h3" = "2" ] && [ "$_h4" = "2" ] && [ "$_h5" = "0" ] && [ "$_h5n" = "0" ] \
   && [ "$_g1" = "0" ] && [ "$_g1l" = "||https://www.newsmaxtv.com/Shows/Show-One/vid/show-one-0 best" ] && [ "$_g2n" = "1" ] && [ "$_g2w" = "1" ] \
   && [ "$_g3l" = "1|45|https://www.newsmaxtv.com/Shows/Show-One/vid/show-one-1 best;1|45|https://www.newsmaxtv.com/Shows/Show-Two/vid/show-two-1 best;" ]; then
  pass "slipmat newsmax end to end: --help prints the words and starts nothing; an unknown word, a row number without back N and more answers than rows end in exit 2 with nothing started; back N with nobody there lists and starts nothing; 'today' rips the one show posted today at its usual and a second run a moment later leaves it alone; 'h yesterday' rips both at native 1080 q45"
else fail "slipmat newsmax end to end: help rc $_h1 calls $_h1n usage $_h1u · refusals $_h2 $_h3 $_h4 · back rc $_h5 calls $_h5n · today rc $_g1 '$_g1l' · second run calls $_g2n said $_g2w · yesterday '$_g3l'" "$S/nmx-out.txt"; fi

# ---- 3f. the silent-file rule (11.2.26): a file without audio says WHICH kind of silent it is —
# the source has no audio track, or the source lists one and none could be fetched.
mkdir -p "$S/silent"
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=160x120:rate=10 -c:v libx264 -pix_fmt yuv420p -an "$S/silent/v.mp4" </dev/null 2>/dev/null
printf '{"formats":[{"format_id":"1","vcodec":"avc1","acodec":"none","height":120,"width":160,"url":"https://e/v"}]}' > "$S/silent/noaudio.json"
printf '{"formats":[{"format_id":"1","vcodec":"avc1","acodec":"none","height":120,"width":160,"url":"https://e/v"},{"format_id":"2","vcodec":"none","acodec":"mp4a.40.2","url":"https://e/a"}]}' > "$S/silent/hasaudio.json"
_sv=$(sed -n '/^source_claims_audio() {/,/^}/p; /^silent_verdict() {/,/^}/p; /^audio_streams() {/,/^}/p' "$ENGINE")
_sa=$(cd "$S/silent" && PYTHON=python3 VR_PY="$_vrpy" FFPROBE="$FFPROBE" INFO="$S/silent/noaudio.json" bash -c "warn() { printf 'W:%s\n' \"\$*\"; }; note() { printf 'N:%s\n' \"\$*\"; }; $_sv; silent_verdict v.mp4; printf 'A:%s\n' \"\$AUDIO_NOTE\"" 2>&1)
_sb=$(cd "$S/silent" && PYTHON=python3 VR_PY="$_vrpy" FFPROBE="$FFPROBE" INFO="$S/silent/hasaudio.json" bash -c "warn() { printf 'W:%s\n' \"\$*\"; }; note() { printf 'N:%s\n' \"\$*\"; }; $_sv; silent_verdict v.mp4; printf 'A:%s\n' \"\$AUDIO_NOTE\"" 2>&1)
if printf '%s' "$_sa" | grep -q '^N:this file is silent by nature' && printf '%s' "$_sa" | grep -q '^A:silent — the source has no audio track' \
   && printf '%s' "$_sb" | grep -q '^W:this file is silent: the source lists an audio track' && printf '%s' "$_sb" | grep -q '^A:silent — the source lists an audio track' \
   && grep -q 'box_line "audio   \$AUDIO_NOTE"' "$ENGINE" && grep -q 'audio_only_rescue "\$DLF"' "$ENGINE" && grep -q 'audio_only_rescue "\$MKV"' "$ENGINE"; then
  pass "the silent-file rule: no audio track → 'silent by nature'; audio listed but none landed → 'none could be fetched'; both on the receipt's audio line; the audio-only rescue sits on both paths"
else fail "the silent-file rule: no-audio dump → '$_sa' · audio-claiming dump → '$_sb'"; fi

# ---- 3h. a second copy of one video at another size is "(720)", at the same size "(2)" (11.3.26); the suffix is
# corrected at placement to the size that landed.
mkdir -p "$S/u"
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=640x360:rate=10 -c:v libx264 -pix_fmt yuv420p -an "$S/u/X.mp4" </dev/null 2>/dev/null
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=320x240:rate=10 -c:v libx264 -pix_fmt yuv420p -an "$S/u/landed.mp4" </dev/null 2>/dev/null
_uq=$(sed -n '/^uniquify() {/,/^}/p; /^file_short_side() {/,/^}/p; /^place_final() {/,/^}/p' "$ENGINE")
_r=$(cd "$S/u" && OUTDIR="$S/u" FFPROBE="$FFPROBE" WORKDIR="" CAPDIR="$S/u" bash -c "logln() { :; }; $_uq; printf '%s|%s|' \"\$(uniquify X 720)\" \"\$(uniquify X 360)\"; NAME='Y (720)'; place_final landed.mp4 'Y (720)' mp4; printf '%s' \"\$NAME\"" 2>&1)
if [ "$_r" = "X (720)|X (2)|Y (240)" ] && [ -s "$S/u/Y (240).mp4" ]; then
  pass "a second copy at another size is X (720), at the same size X (2); a (720) that landed at 240 is placed as Y (240)"
else fail "size suffix: '$_r'"; fi

# ---- 3h2. the Newsmax name paths reach the same rule (11.6.26): size_suffix names a second copy of a show by the
# size that LANDED when a finished file already holds the stem at another size; the show-door name passes the pick
# to uniquify; the naming window's two renames (finish line, late) run the rule before they claim a name.
mkdir -p "$S/u2"
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=640x360:rate=10 -c:v libx264 -pix_fmt yuv420p -an "$S/u2/X.mp4" </dev/null 2>/dev/null
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=320x240:rate=10 -c:v libx264 -pix_fmt yuv420p -an "$S/u2/L.mp4" </dev/null 2>/dev/null
_sx=$(sed -n '/^size_suffix() {/,/^}/p; /^file_short_side() {/,/^}/p' "$ENGINE")
_r=$(cd "$S/u2" && OUTDIR="$S/u2" FFPROBE="$FFPROBE" bash -c "$_sx; printf '%s|%s|%s|%s|%s' \"\$(size_suffix X L.mp4)\" \"\$(size_suffix X 240)\" \"\$(size_suffix X 360)\" \"\$(size_suffix X '')\" \"\$(size_suffix NOFILE L.mp4)\"" 2>&1)
if [ "$_r" = "X (240)|X (240)|X|X|NOFILE" ] && grep -q 'uniquify "\$_nrow \$_ndate \[NMX\]" "\$_pick_h"' "$ENGINE" \
   && grep -q '_qnew=\$(size_suffix "\$_qnew" "\$OUT")' "$ENGINE" && grep -q 'NEW="\\\$NEW (\\\$NH)"' "$ENGINE"; then
  pass "a Newsmax second copy at another size is named by the size that landed (X (240)); the same size, no pick or no first copy leave the stem; the show-door name, the finish-line rename and the late rename all run the rule"
else fail "newsmax size suffix: '$_r'"; fi

# ---- 3i. a YouTube link that names one video and its playlist is cut to that video (11.4.26); a playlist dump
# of YouTube entries hands back the page of the entry the link names, never a bare googlevideo file.
_yo=$(sed -n '/^yt_one_video() {/,/^}/p' "$ENGINE")
_r=""
for _u in 'https://www.youtube.com/watch?v=GhZZojpNOB4&list=PLToGD5c9nKsY&index=5' 'https://youtu.be/GhZZojpNOB4?list=PLx&t=90' 'https://www.youtube.com/playlist?list=PLx' 'https://www.youtube.com/watch?v=Sz1u2twE4n4'; do
  _r="$_r$(URL="$_u" bash -c "ok() { :; }; logln() { :; }; $_yo; yt_one_video; printf '%s' \"\$URL\"" 2>&1)|"
done
mkdir -p "$S/pl"
printf '%s' '{"_type":"playlist","extractor_key":"YoutubeTab","entries":[{"id":"LEAD0000001","title":"Lead","extractor_key":"Youtube","webpage_url":"https://www.youtube.com/watch?v=LEAD0000001","formats":[{"format_id":"18","vcodec":"avc1","acodec":"mp4a","height":360,"width":640,"protocol":"https","url":"https://rr5.googlevideo.com/videoplayback?itag=18"}]},{"id":"NAMED000001","title":"Named","extractor_key":"Youtube","webpage_url":"https://www.youtube.com/watch?v=NAMED000001","formats":[{"format_id":"18","vcodec":"avc1","acodec":"mp4a","height":360,"width":640,"protocol":"https","url":"https://rr5.googlevideo.com/videoplayback?itag=18"}]}]}' > "$S/pl/list.json"
_p1=$(python3 -c "$_vrpy" plrescue 'https://www.youtube.com/watch?v=NAMED000001&list=PLx&index=2' < "$S/pl/list.json" 2>/dev/null | tr '\037' '|')
_p2=$(python3 -c "$_vrpy" plrescue 'https://www.youtube.com/playlist?list=PLx' < "$S/pl/list.json" 2>/dev/null | tr '\037' '|')
if [ "$_r" = "https://www.youtube.com/watch?v=GhZZojpNOB4|https://www.youtube.com/watch?v=GhZZojpNOB4&t=90|https://www.youtube.com/playlist?list=PLx|https://www.youtube.com/watch?v=Sz1u2twE4n4|" ] \
   && [ "$_p1" = "2|Named|NAMED000001||https://www.youtube.com/watch?v=NAMED000001||Lead||1" ] \
   && [ "$_p2" = "2|Lead|LEAD0000001||https://www.youtube.com/watch?v=LEAD0000001||Named||" ] \
   && grep -q '^  yt_one_video ' "$ENGINE"; then
  pass "a watch?v=…&list= link is cut to its one video (a start time kept; a bare playlist link and a plain watch link untouched); a playlist dump hands back the named YouTube entry as its page, never a bare googlevideo file"
else fail "one video in a playlist: urls='$_r' · named='$_p1' · lead='$_p2'"; fi

# ---- 3c6. a livestream whose playlist keeps its history can be rewound on any site (11.12.26, Rumble): the
# playlist is read once and ffmpeg is told which piece to begin at: the oldest for from-start, K from the end
# for a last-N window (12 s of margin), three in on a sliding window; a playlist that ended, a pick that is
# not a playlist and a window longer than the history are each answered the right way.
_hf=$(sed -n '/^hls_history() {/,/^}/p' "$ENGINE")
mkdir -p "$S/hls"
_mk() { { printf '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:%s\n' "$2"; _i=0; while [ "$_i" -lt 300 ]; do printf '#EXTINF:2.000,\nseg_%s.ts\n' "$_i"; _i=$((_i+1)); done; [ "$3" = "end" ] && printf '#EXT-X-ENDLIST\n'; } > "$S/hls/$1.m3u8"; }
_mk whole 1 live; _mk slide 5000 live; _mk ended 1 end
for _n in whole slide ended; do
  printf '{"formats":[{"format_id":"file-0","protocol":"https","url":"https://example.com/a.mp4","height":720},{"format_id":"hls-1","protocol":"m3u8_native","url":"file://%s/hls/%s.m3u8","height":360,"vcodec":null,"http_headers":{"User-Agent":"smoke"}}]}' "$S" "$_n" > "$S/hls/$_n.json"
done
_hh() { PYTHON="$(command -v python3)" bash -c "$_hf; hls_history \"\$1\" \"\$2\" \"\$3\"" _ "$S/hls/$1.json" "$2" "$3" 2>/dev/null; }
_h1=$(_hh whole -1 ""); _h2=$(_hh whole 0 hls-1); _h3=$(_hh whole 120 hls-1); _h4=$(_hh whole 900 hls-1)
_h5=$(_hh slide 0 hls-1); _h6=$(_hh ended 0 hls-1); _h7=$(_hh whole 0 file-0)
if [ "$_h1" = "600 1 0 0 600" ] && [ "$_h2" = "600 1 0 0 600" ] && [ "$_h3" = "600 1 -66 -66 132" ] && [ "$_h4" = "600 1 0 0 600" ] \
   && [ "$_h5" = "600 5000 3 3 594" ] && [ -z "$_h6" ] && [ -z "$_h7" ] \
   && grep -q 'live_start_index \$_hi1' "$ENGINE" && grep -q 'LIVE_HLS_DA\[@\]+' "$ENGINE" \
   && grep -q "SLIPMAT_LIVE_HLS" "$REPO/tools/live-rewind.py" && grep -q 'out_time_us=' "$REPO/tools/live-rewind.py" \
   && ! grep -q 'only works on YouTube' "$ENGINE"; then
  pass "a live playlist that keeps its history is rewound on any site: from-start begins at the oldest piece, last-2m at 66 pieces from the end, a sliding window three pieces in; an ended playlist and a pick that is not a playlist are left to record from now; the capture hands ffmpeg the start piece and the driver reads its progress"
else fail "playlist rewind: measure='$_h1' · start='$_h2' · last-2m='$_h3' · last-15m='$_h4' · sliding='$_h5' · ended='$_h6' · not a playlist='$_h7'"; fi

# ---- 3c7. ffmpeg refuses a live playlist whose pieces carry no media file ending (11.12.26, a station's linear
# channel: each piece is a tracking address that redirects to the .ts). The refusal is ffmpeg's own sentence;
# with nothing landed the capture runs once more with that one check off. A capture that has a file, or one
# that died of anything else, is never restarted. The sentence the engine reads is asked of this ffmpeg too.
_lr=$(sed -n '/^live_refused_ending() {/,/^}/p' "$ENGINE")
mkdir -p "$S/picky/none" "$S/picky/some" "$S/picky/ff"
: > "$S/picky/none/A [id].mp4.part"; : > "$S/picky/none/A [id].mp4.claim"; printf 'x' > "$S/picky/none/B other.mp4"
printf 'x' > "$S/picky/some/A [id].mp4.part"
printf '[in#0 @ 0x1] URL https://example.com/beacon/640x360_1?seg_id=1 is not in allowed_segment_extensions, consider updating hls.c\n' > "$S/picky/refused.log"
printf 'ERROR: unable to download video data: HTTP Error 403: Forbidden\n' > "$S/picky/other.log"
_lre() { bash -c "$_lr; live_refused_ending \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "$3" 2>/dev/null; echo $?; }
_p1=$(_lre "$S/picky/refused.log" "$S/picky/none" "A [id]"); _p2=$(_lre "$S/picky/refused.log" "$S/picky/some" "A [id]")
_p3=$(_lre "$S/picky/other.log" "$S/picky/none" "A [id]");   _p4=$(_lre "$S/picky/missing.log" "$S/picky/none" "A [id]")
_p5="no such check in this ffmpeg"
if "$FFMPEG" -hide_banner -h demuxer=hls 2>/dev/null | grep -q 'extension_picky'; then
  "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=160x90:rate=10 -c:v libx264 -pix_fmt yuv420p -an -f mpegts "$S/picky/ff/seg_0" </dev/null 2>/dev/null
  printf '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1.000,\nseg_0\n#EXT-X-ENDLIST\n' > "$S/picky/ff/p.m3u8"
  _pa=$("$FFMPEG" -hide_banner -loglevel error -y -i "$S/picky/ff/p.m3u8" -c copy "$S/picky/ff/a.mp4" </dev/null 2>&1)
  _pb=$("$FFMPEG" -hide_banner -loglevel error -y -extension_picky 0 -i "$S/picky/ff/p.m3u8" -c copy "$S/picky/ff/b.mp4" </dev/null 2>&1)
  case "$_pa" in
    *allowed_segment_extensions*) case "$_pb" in *allowed_segment_extensions*) _p5="the check stayed on with -extension_picky 0" ;; *) _p5=ok ;; esac ;;
    *) _p5="this ffmpeg words the refusal another way" ;;
  esac
fi
if [ "$_p1" = "0" ] && [ "$_p2" = "1" ] && [ "$_p3" = "1" ] && [ "$_p4" = "1" ] \
   && { [ "$_p5" = "ok" ] || [ "$_p5" = "no such check in this ffmpeg" ]; } \
   && [ "$(grep -c 'ffmpeg_i:-loglevel error\$LIVE_XARG' "$ENGINE")" = "2" ] && grep -q 'LIVE_XARG=" -extension_picky 0"' "$ENGINE" \
   && grep -q 'LIVE_HLS_DA\[@\]/-loglevel error/-loglevel error -extension_picky 0' "$ENGINE"; then
  pass "a live playlist whose pieces carry no media file ending: ffmpeg's refusal with nothing landed is read from the capture's log and the capture runs once more with that one check off, on every input; a capture that has a file, or any other death, is never restarted ($_p5)"
else fail "piece-address refusal: refused+nothing='$_p1' (0) · refused+a file='$_p2' (1) · another death='$_p3' (1) · no log='$_p4' (1) · this ffmpeg: $_p5"; fi

# ---- 3j. a cbs.com video page is read by the engine itself (11.12.26): yt-dlp's CBS extractor answers empty,
# the page's own player data gives the manifest, the title, the id, the air date and the length; a page that
# marks its video protected, or one on another site, is never taken by this reader.
_eh=$(sed -n '/^embed_hunt() {/,/^}/p' "$ENGINE")
mkdir -p "$S/cbs"
_cbsmd='{"label":"A label","title":"A  clip title","contentId":"ALVE0000000000000000000000TEST","_airDate":"10\/22\/26 08:38 EDT","_airDateISO":"2026-10-22T05:38:00-07:00","duration":381,"fullEpisode":false,"streamingUrl":"https:\/\/clips.example.com\/2026\/10\/22\/x\/stream.mpd","isProtected":false,"thumbnailSet":[{"height":360}]}'
printf '<html><script>\n  player.apiMetadata = %s;\n  player.drm = null;\n</script></html>\n' "$_cbsmd" > "$S/cbs/free.html"
sed 's/"isProtected":false/"isProtected":true/' "$S/cbs/free.html" > "$S/cbs/protected.html"
_hunt() { SLIPMAT_HUNT_PAGE="$1" ZPYTHON="$(command -v python3)" bash -c "$_eh; embed_hunt '$2'" 2>/dev/null | tr '\037' '|'; }
_c1=$(_hunt "$S/cbs/free.html" 'https://www.cbs.com/shows/video/ALVE0000000000000000000000TEST/')
_c2=$(_hunt "$S/cbs/protected.html" 'https://www.cbs.com/shows/video/ALVE0000000000000000000000TEST/')
_c3=$(_hunt "$S/cbs/free.html" 'https://www.example.com/shows/video/ALVE0000000000000000000000TEST/')
if [ "$_c1" = "CBS clip|https://clips.example.com/2026/10/22/x/stream.mpd|A clip title|ALVE0000000000000000000000TEST|20261022||381" ] \
   && [ -z "$_c2" ] && [ -z "$_c3" ] \
   && grep -q 'RESCUE_DUR=.*-f7' "$ENGINE" && grep -q '\*://www.cbs.com/\*|\*://cbs.com/\*) \[ -n "\${RESCUE_DATE' "$ENGINE"; then
  pass "a cbs.com video page is read from its own player data: manifest, title, id, air date and length; a protected page and another site's page are left alone; the page's date and length reach the name and the receipt"
else fail "cbs.com page reader: free='$_c1' · protected='$_c2' · other site='$_c3'"; fi

# ---- 3j2. a page that holds no stream address is followed to its stream (11.12.26, a radio show's site): the
# page reader walks what the page loads — a same-site watch link, the player script on that page, the player
# address that script spells from its own constants, the answer that names the playlist — and takes the
# playlist only when it answers as one and names no DRM key system. A link to the audio stream is never
# followed, a broken chain gives nothing, and a bare playlist is named by the page's title.
mkdir -p "$S/follow"
printf '<html><head><title>A Show</title></head><body><a href="/listenlive">Listen Live</a> <a class="b" href="https://www.example.org/watch-the-show">Watch the <b>Show</b></a></body></html>\n' > "$S/follow/home.html"
printf '<html><head><title>Watch the Show - A Show</title></head><body><div id="snc-player"></div><script src="https://cdn.example.net/js/gtag-analytics.js"></script><script src="https://player.example.net/js/embed-player.js"></script></body></html>\n' > "$S/follow/watch.html"
printf "(function () {\n  const LIVE_ID = 'abc123'\n  const KEY = 'k9'\n  let src = \`https://player.zype.com/embed/\${LIVE_ID}.js?api_key=\${KEY}&controls=true\`\n  const other = \`https://api.example.net/v1/shows?host=\${host}\`\n})()\n" > "$S/follow/embed-player.js"
printf 'var cfg = {"title":"Live TV","sources":[{"file":"https:\\/\\/cdn.example.net\\/linear\\/chan\\/playlist.m3u8?"}]};\n' > "$S/follow/zype.js"
printf '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=1020588,RESOLUTION=640x360\nhttps://cdn.example.net/linear/chan/360/index.m3u8\n' > "$S/follow/open.m3u8"
printf '#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://k",KEYFORMAT="com.apple.streamingkeydelivery"\n#EXT-X-STREAM-INF:BANDWIDTH=1020588\nhttps://cdn.example.net/linear/chan/360/index.m3u8\n' > "$S/follow/drm.m3u8"
printf '<html><head><title>Watch</title><meta property="og:title" content="Watch"></head><body><script>var s={"hls":"https://cdn.example.net/live/master.m3u8"}</script></body></html>\n' > "$S/follow/raw.html"
_fmap() { printf '{"https://www.example.org/watch-the-show":"%s/follow/watch.html","https://player.example.net/js/embed-player.js":"%s/follow/embed-player.js"%s,"https://cdn.example.net/linear/chan/playlist.m3u8?":"%s/follow/%s.m3u8"}' "$S" "$S" "$2" "$S" "$1" > "$S/follow/map-$1$3.json"; }
_fz=",\"https://player.zype.com/embed/abc123.js?api_key=k9&controls=true\":\"$S/follow/zype.js\""
_fmap open "$_fz" ""; _fmap drm "$_fz" ""; _fmap open "" "-broken"
_fh() { SLIPMAT_HUNT_MAP="$S/follow/map-$1.json" SLIPMAT_HUNT_PAGE="$S/follow/$2" ZPYTHON="$(command -v python3)" bash -c "$_eh; embed_hunt '$3'" 2>/dev/null | tr '\037' '|'; }
_f1=$(_fh open home.html 'https://www.example.org/?utm_source=x'); _f2=$(_fh open watch.html 'https://www.example.org/watch-the-show')
_f3=$(_fh drm home.html 'https://www.example.org/'); _f4=$(_fh open-broken home.html 'https://www.example.org/'); _f5=$(_fh open raw.html 'https://www.example.org/watch')
if [ "$_f1" = "the stream its player loads, found on /watch-the-show|https://cdn.example.net/linear/chan/playlist.m3u8?|Watch the Show - A Show||||" ] \
   && [ "$_f2" = "the stream its player loads|https://cdn.example.net/linear/chan/playlist.m3u8?|Watch the Show - A Show||||" ] \
   && [ -z "$_f3" ] && [ -z "$_f4" ] && [ "$_f5" = "manifest in page|https://cdn.example.net/live/master.m3u8|Watch - example.org||||" ] \
   && grep -q '"manifest in page"|"the stream its player loads"\*)' "$ENGINE" && grep -q 'RESCUE_NOID:-0}" = "1" \] && \[ -z "\${RESCUE_ID:-}" \] && M_ID=""' "$ENGINE"; then
  pass "a page with no stream address is followed to its stream: home page → its watch link → the player script → the player address spelled from the script's constants → the playlist; a DRM playlist and a broken chain give nothing; a bare playlist takes the page's title (a one-word title gets the site beside it) and no bracket"
else fail "follow the player: home='$_f1' · watch page='$_f2' · DRM='$_f3' · broken chain='$_f4' · raw playlist='$_f5'"; fi

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
# 11.2.26: SLIPMAT_Q sets the dial for one no-questions run (the Newsmax `high` answer rides on it)
HOME="$FH" SLIPMAT_LOCAL_MKV="$FX/clean.mkv" SLIPMAT_Q=45 "$ENGINE" "https://example.test/clean-q45" max best </dev/null > "$S/run5q.txt" 2>&1
_l5q=$(newest_log)
if [ -n "$_l5q" ] && grep -q 're-encoding → .*q45' "$_l5q"; then pass "SLIPMAT_Q=45 sets the dial of a BEST re-encode (the log says q45)"
else fail "SLIPMAT_Q=45 did not reach the re-encode (the dial default is set after the environment is read?)" "$_l5q"; fi
if [ -n "$_l5" ] && ! grep -q 'heads-up' "$_l5"; then pass "BEST is wordless: no size heads-up on a URL rip (local files and STUDIO only)"
else fail "BEST printed a size heads-up (ruled local + STUDIO only)" "$_l5"; fi
if [ -n "$_l5" ] && comma_clean "$_l5"; then pass "probed values comma-free in the BEST log"
else fail "a probed value carries ffprobe's trailing comma (BEST log)" "$_l5"; fi

# ---- 5b. the title hook (11.3.26): it gets title · channel · source tag and may answer NAME <TAB> date <TAB> tag;
# "-" as the tag writes no bracket, its date outranks the upload date; the menu-bar door for the day's shows exists.
mkdir -p "$FH/.slipmat"
cat > "$FH/.slipmat/title-hook" <<'HEOF'
#!/bin/bash
printf 'SMART NAME\t10.21.26\t-\n'
HEOF
chmod 755 "$FH/.slipmat/title-hook"
HOME="$FH" SLIPMAT_LOCAL_MKV="$FX/clean.mkv" "$ENGINE" "https://example.test/clean-hook" max best </dev/null > "$S/run-hook.txt" 2>&1 || true
rm -f "$FH/.slipmat/title-hook"
if [ -s "$OUT/SMART NAME - 10.21.26.mp4" ] && grep -q 'mode is "newsmax"' "$REPO/shortcuts/launch.applescript" && grep -q '"\[SLIPMAT VIDEO\] NEWSMAX" newsmax' "$REPO/shortcuts/make-shortcuts.sh"; then
  pass "the title hook names the file from its three answers (SMART NAME - 10.21.26: the hook's date, no bracket tag); the NEWSMAX menu-bar door is built and handled"
else fail "the title hook protocol: $(ls "$OUT" | grep -i 'smart' | head -2 | tr '\n' ' ')" "$S/run-hook.txt"; fi

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
