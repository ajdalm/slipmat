#!/bin/bash
# z-batch.sh — unattended zoom-crop (Z) on files and/or folders.
# usage: z-batch.sh [-c N] [-q N] [-d SUBDIR] <file|folder> ...
#   -c N       quality dial for CROP encodes (default 56 — cropped PiP sources are
#              usually low-res already, so they get the gentler setting)
#   -q N       quality dial for plan-B plain re-encodes (default 45)
#   -d SUBDIR  move successful crops ([Z] outputs) into <source folder>/SUBDIR/
#              (no -d = the [Z] lands beside its source)
# Rules:
#   folders expand NON-recursive to .mp4/.mkv/.mov · files already [Z]-named, with an
#   existing [Z] sibling (beside or in SUBDIR), or with a (qN) plan-B sibling are
#   SKIPPED (that's the resume mechanism) · SEQUENTIAL, one encode at a time (the
#   hardware encoder is shared) · a per-file failure never stops the batch · summary
#   table at the end · ONE batch log in ~/.slipmat/logs/<day>/ beside the per-run logs.
# Each file runs the REAL engine's interactive z flow, auto-answered via
# SLIPMAT_Z_AUTO=1 (see slipmat-video ask_line): fresh hunt at standard depth, FIRST box
# accepted, 20-85% sanity rail, out-of-rail/no-box = plan B (plain re-encode, same q,
# no crop), quality flags always (never the fast recipe).
set -u
Q=45; QC=56; SUBDIR=""
# -q = the plan-B (plain) dial · -c = the CROP dial (low-res PiP sources visibly
# degrade at 45; 9.24: crops default to q56 — q55≡q56 is one real bucket, less added
# banding in dark scenes than q50 at +34% size, measured with `slipmat compare`)
num() { case "$2" in ''|*[!0-9]*) echo "z-batch: -$1 needs a number (got '$2')"; exit 1 ;; esac; }
while getopts "q:c:d:" _o; do case $_o in
  q) num q "$OPTARG"; Q=$OPTARG ;; c) num c "$OPTARG"; QC=$OPTARG ;; d) SUBDIR=$OPTARG ;;
  *) echo "usage: z-batch.sh [-c N] [-q N] [-d SUBDIR] <file|folder> ..."; exit 1 ;; esac; done
shift $((OPTIND-1))
[ $# -ge 1 ] || { echo "z-batch: nothing to do — pass files or folders"; exit 1; }
VR="${SLIPMAT_ENGINE:-$(dirname "$0")/../engine/slipmat-video}"
DAY=$(date +%F); LOGD="$HOME/.slipmat/logs/$DAY"; mkdir -p "$LOGD"

# ---- expand the selection (folders: non-recursive, video extensions only) ----
FILES=()
is_video(){ case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in *.mp4|*.mkv|*.mov) return 0;; *) return 1;; esac; }
for a in "$@"; do
  if [ -d "$a" ]; then
    while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(find "$a" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' \) | sort)
  elif [ -f "$a" ] && is_video "$a"; then FILES+=("$a")
  else echo "  ! skipping \"$a\" — not a video file or folder"; fi
done
[ ${#FILES[@]} -ge 1 ] || { echo "z-batch: no videos found in the selection"; exit 1; }

BLOG="$LOGD/$(date +%H%M%S) Z-BATCH (${#FILES[@]} files · crops q${QC} · plains q${Q} · quality · z-auto).log"
say(){ printf '%s\n' "$*"; printf '%s\n' "$*" | sed $'s/\033\\[[0-9;]*m//g' >> "$BLOG"; }
printf '\033]0;Z AUTO BATCH · %s files · q%s\007' "${#FILES[@]}" "$Q"
say "Z-BATCH $(date '+%Y-%m-%d %H:%M:%S') — ${#FILES[@]} file(s) · crops q${QC} · plains q${Q} · quality · z-auto${SUBDIR:+ · crops → ./$SUBDIR/}"
say ""
/usr/bin/caffeinate -i -w $$ &   # the night run survives idle sleep; released when the batch exits

# summary rows collect here (parallel arrays — bash 3.2)
R_NAME=(); R_RES=(); R_SIZE=(); R_TIME=(); FAILS=0
n=0
for SRC in "${FILES[@]}"; do
  n=$((n+1))
  base=$(basename "$SRC"); dir=$(dirname "$SRC"); stem="${base%.*}"
  printf '\033]0;Z AUTO %s/%s · %s\007' "$n" "${#FILES[@]}" "$base"
  say "── [$n/${#FILES[@]}] $base"
  # resume mechanism: outputs are never inputs; done files are skipped
  case "$stem" in
    *" [Z]"|*" [Z] ("*")") say "   skipped — already a [Z] output"; R_NAME+=("$base"); R_RES+=("skipped — is a [Z] output"); R_SIZE+=("-"); R_TIME+=("-"); continue ;;
    *" (q"[0-9]*")") say "   skipped — already a plan-B output"; R_NAME+=("$base"); R_RES+=("skipped — is a (q) output"); R_SIZE+=("-"); R_TIME+=("-"); continue ;;
  esac
  # the engine renames a BARE-TIMESTAMP source (YYYYMMDD_HHMMSS) to its date form
  # ("5.19.26 - 11.57AM [Z]") — derive it so resume still recognizes the done file
  zname="$stem [Z].mp4"
  case "$stem" in
    [12][0-9][0-9][0-9][01][0-9][0-3][0-9]_[0-2][0-9][0-5][0-9][0-5][0-9])
      zname=$(printf '%s' "$stem" | awk -F_ '{y=substr($1,1,4); m=substr($1,5,2)+0; d=substr($1,7,2)+0;
        H=substr($2,1,2)+0; M=substr($2,3,2); ap="AM"; h=H; if(H>=12){ap="PM"; if(H>12)h=H-12} else if(H==0)h=12;
        printf "%d.%d.%s - %d.%s%s [Z].mp4", m, d, substr(y,3,2), h, M, ap }') ;;
  esac
  if [ -e "$dir/$stem [Z].mp4" ] || [ -e "$dir/$zname" ]      || { [ -n "$SUBDIR" ] && { [ -e "$dir/$SUBDIR/$stem [Z].mp4" ] || [ -e "$dir/$SUBDIR/$zname" ]; }; }; then
    say "   skipped — [Z] already exists"; R_NAME+=("$base"); R_RES+=("skipped — [Z] exists"); R_SIZE+=("-"); R_TIME+=("-"); continue
  fi
  if [ -e "$dir/$stem (q${Q}).mp4" ]; then
    say "   skipped — plan-B (q${Q}) already exists"; R_NAME+=("$base"); R_RES+=("skipped — (q${Q}) exists"); R_SIZE+=("-"); R_TIME+=("-"); continue
  fi
  T0=$SECONDS
  OUT=$(SLIPMAT_Z_AUTO=1 SLIPMAT_Z_Q=$Q SLIPMAT_Z_QCROP=$QC "$VR" "$SRC" studio </dev/null 2>&1)
  RC=$?
  printf '%s\n' "$OUT" | sed $'s/\033\\[[0-9;]*m//g' >> "$BLOG"
  TK=$((SECONDS-T0)); TKS=$(printf '%d:%02d' $((TK/60)) $((TK%60)))
  SB=$(stat -f %z "$SRC" 2>/dev/null || echo 0)
  boxline=$(printf '%s\n' "$OUT" | grep -oE 'found a [0-9]+x[0-9]+ box at \([0-9]+,[0-9]+\) in [0-9]+x[0-9]+ — [0-9]+% of the frame' | head -1)
  [ -z "$boxline" ] && boxline=$(printf '%s\n' "$OUT" | grep -oE 'z-auto rail: a [0-9]+x[0-9]+ box \([0-9]+% of frame\)' | head -1)
  box=$(printf '%s' "$boxline" | grep -oE '[0-9]+x[0-9]+ box' | awk '{print $1}')
  pct=$(printf '%s' "$boxline" | grep -oE '[0-9]+% of (the )?frame' | grep -oE '^[0-9]+')
  ZOUT="$dir/$stem [Z].mp4"; POUT="$dir/$stem (q${Q}).mp4"
  # the receipt names the REAL output (bare-timestamp sources get renamed) — trust it
  rname=$(printf '%s\n' "$OUT" | grep -oE 'encoded .*\[Z\]( \([0-9]+\))?\.mp4' | head -1 | sed 's/^encoded //')
  [ -n "$rname" ] && [ -s "$dir/$rname" ] && ZOUT="$dir/$rname"
  if [ -s "$ZOUT" ]; then
    ZB=$(stat -f %z "$ZOUT"); PCTD=$(awk -v a="$SB" -v b="$ZB" 'BEGIN{ if(a>0){ d=(1-b/a)*100; if(d>=0) printf "−%d%%", d; else printf "+%d%%", -d } }')
    DEST="$ZOUT"
    if [ -n "$SUBDIR" ]; then
      _t="$dir/$SUBDIR/$(basename "$ZOUT")"
      if [ -e "$_t" ]; then say "   (kept beside its source — $SUBDIR/ already holds that name)"
      else mkdir -p "$dir/$SUBDIR" && mv "$ZOUT" "$_t" && DEST="$_t"; fi
    fi
    say "   ✓ crop ${box:-?} (${pct:-?}% of frame) · $(awk -v b="$SB" 'BEGIN{printf "%.0fM", b/1048576}')→$(awk -v b="$ZB" 'BEGIN{printf "%.0fM", b/1048576}') ($PCTD) · $TKS · q${QC}"
    R_NAME+=("$base"); R_RES+=("crop ${box:-?} · ${pct:-?}%"); R_SIZE+=("$(awk -v a="$SB" -v b="$ZB" 'BEGIN{printf "%.0fM→%.0fM", a/1048576, b/1048576}') $PCTD"); R_TIME+=("$TKS")
  elif [ -s "$POUT" ]; then
    PB=$(stat -f %z "$POUT"); PCTD=$(awk -v a="$SB" -v b="$PB" 'BEGIN{ if(a>0){ d=(1-b/a)*100; if(d>=0) printf "−%d%%", d; else printf "+%d%%", -d } }')
    why="no box"; printf '%s\n' "$OUT" | grep -q 'z-auto rail' && why="rail: box ${pct:-?}%"
    printf '%s\n' "$OUT" | grep -q "that's [0-9]*% of the frame" && why="box ≈ full frame"
    say "   ○ $why — plain re-encode · $(awk -v b="$SB" 'BEGIN{printf "%.0fM", b/1048576}')→$(awk -v b="$PB" 'BEGIN{printf "%.0fM", b/1048576}') ($PCTD) · $TKS · q${Q}"
    R_NAME+=("$base"); R_RES+=("$why — plain"); R_SIZE+=("$(awk -v a="$SB" -v b="$PB" 'BEGIN{printf "%.0fM→%.0fM", a/1048576, b/1048576}') $PCTD"); R_TIME+=("$TKS")
  elif printf '%s\n' "$OUT" | grep -q 'keeping your file untouched'; then
    # the engine declined on purpose (e.g. the shrink guard: a q re-encode would not
    # shrink an efficient source) — that is a kept file, not a failure
    why="kept untouched"; printf '%s\n' "$OUT" | grep -q 'will NOT shrink' && why="kept — q${Q} wouldn't shrink it"
    say "   ○ $why · $TKS"
    R_NAME+=("$base"); R_RES+=("$why"); R_SIZE+=("-"); R_TIME+=("$TKS")
  else
    err=$(printf '%s\n' "$OUT" | grep -E '\[slipmat ERROR\]' | tail -1 | cut -c1-90)
    say "   ✗ FAILED (exit $RC) ${err:+— $err}"
    R_NAME+=("$base"); R_RES+=("FAILED (exit $RC)"); R_SIZE+=("-"); R_TIME+=("$TKS"); FAILS=$((FAILS+1))
  fi
done

say ""
say "═══ Z-BATCH SUMMARY · ${#FILES[@]} file(s) · crops q${QC} · plains q${Q} · quality · z-auto ═══"
i=0
while [ $i -lt ${#R_NAME[@]} ]; do
  say "$(printf '%-52.52s  %-28s  %-18s  %s' "${R_NAME[$i]}" "${R_RES[$i]}" "${R_SIZE[$i]}" "${R_TIME[$i]}")"
  i=$((i+1))
done
say ""
say "batch log: $BLOG"
printf '\033]0;Z AUTO BATCH done · %s files\007' "${#FILES[@]}"
[ "$FAILS" -eq 0 ]   # exit status: 1 if any file failed
