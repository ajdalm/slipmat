#!/bin/bash
# compare.sh — measure quality dials on YOUR file before committing to one.
# usage: slipmat compare [-n WINDOWS] [-s SECS] [-c W:H:X:Y] [--no-open] <file> <q> <q> [...]
#   e.g. slipmat compare "REHEARSAL.mp4" 50 56 60
#   -n N        sample windows spread across the file (default 6)
#   -s S        seconds per window (default 10)
#   -c W:H:X:Y  score a crop (the zoom-crop box from a [Z] receipt), not the whole frame
#   --no-open   don't open the comparison clip in QuickTime
# What it does: cuts N short windows from the source, encodes each at every dial with the
# engine's exact quality recipe (hevc_videotoolbox -q:v, CFR at the source rate, hvc1), and
# scores each against the untouched source three ways:
#   VMAF     perceptual score (the source scored against itself ≈ 97.5 = the ceiling)
#   NEG      the VMAF model that sharpening can't inflate (the stricter of the two)
#   CAMBI    banding in smooth/dark gradients — VMAF's known blind spot (≈5 = visible)
# Then: one table (size projected to the whole file, averages AND worst moments), a
# plain-words verdict per dial, a PROVISIONAL pick, and a labeled clip — original | lowest
# dial | highest dial, plus damage maps (brighter = more changed, ×6) — opened for you.
# Nothing is written beside your file. Every run appends to ~/.slipmat/logs/compare-ledger.tsv
# (one row per dial) so the thresholds can be reviewed against many files later.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SLIPMAT_PYTHON=""; FFMPEG=ffmpeg; FFPROBE=ffprobe
[ -f "$HOME/.slipmat/config" ] && . "$HOME/.slipmat/config"
PY="${SLIPMAT_PYTHON:-python3}"; command -v "$PY" >/dev/null 2>&1 || PY=python3
N=6; SECS=10; CROP=""; OPEN=1; ARGS=()
while [ $# -gt 0 ]; do case "$1" in
  -n) N="${2:-}"; shift 2 ;; -s) SECS="${2:-}"; shift 2 ;; -c) CROP="${2:-}"; shift 2 ;;
  --no-open) OPEN=0; shift ;; -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) ARGS+=("$1"); shift ;; esac; done
die() { printf '  ✗ compare: %s\n' "$*" >&2; exit 1; }
[ ${#ARGS[@]} -ge 3 ] || die "give a file and at least two dials — e.g. slipmat compare \"file.mp4\" 50 60"
SRC="${ARGS[0]}"; QS=("${ARGS[@]:1}")
[ -f "$SRC" ] || die "no such file: $SRC"
for q in "${QS[@]}"; do case "$q" in ''|*[!0-9]*) die "dials are numbers (got '$q')" ;; esac; done
case "$N$SECS" in *[!0-9]*) die "-n and -s take whole numbers" ;; esac
[ -z "$CROP" ] || case "$CROP" in *[!0-9:]*|*:*:*:*:*) die "-c takes W:H:X:Y (numbers)" ;; esac
"$FFMPEG" -hide_banner -filters 2>/dev/null | grep -q libvmaf \
  || die "this ffmpeg has no libvmaf (Homebrew's ffmpeg does: brew install ffmpeg)"
QS=($(printf '%s\n' "${QS[@]}" | sort -n | uniq))

DUR=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$SRC" | cut -d. -f1)
RATE=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$SRC")
SINFO=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name,width,height,bit_rate -of csv=p=0 "$SRC")
[ -n "$DUR" ] && [ "$DUR" -gt 0 ] || die "can't read the duration"
[ $((N*SECS)) -lt "$DUR" ] || { N=1; SECS=$(( DUR<10 ? DUR : 10 )); }
VF=""; [ -n "$CROP" ] && VF="-vf crop=$CROP"

TS=$(date +%Y%m%d-%H%M%S); W="$HOME/.slipmat/work/cmp_${TS}_$$"; mkdir -p "$W" || die "can't make $W"
trap 'rm -rf "$W"' EXIT
STEM=$(basename "${SRC%.*}"); OUTD="$HOME/.slipmat/compare/$(printf '%s' "$STEM" | cut -c1-80) $TS"; mkdir -p "$OUTD"
LOGD="$HOME/.slipmat/logs/$(date +%F)"; mkdir -p "$LOGD"
printf '\n SLIPMAT COMPARE  ·  %s\n' "$(basename "$SRC")"
SB=$(stat -f %z "$SRC"); SMB=$(awk -v b="$SB" 'BEGIN{ if (b>=1073741824) printf "%.2f GB", b/1073741824; else printf "%.0f MB", b/1048576 }')
IFS=, read -r _sc _sw _sh _sbr <<< "$SINFO"; case "$_sbr" in ''|*[!0-9]*) _sbr="" ;; *) _sbr=" · $((_sbr/1000)) kbps" ;; esac
printf '  source  %s · %s %sx%s%s\n' "$SMB" "$_sc" "$_sw" "$_sh" "$_sbr"
printf '  dials   %s · %s windows × %ss%s\n' "${QS[*]}" "$N" "$SECS" "${CROP:+ · crop $CROP}"

i=0
while [ $i -lt "$N" ]; do
  st=$(( DUR*(2*i+1)/(2*N) - SECS/2 )); [ $st -lt 0 ] && st=0
  printf '  window %s/%s at %s:%02d …' $((i+1)) "$N" $((st/60)) $((st%60))
  "$FFMPEG" -v error -y -ss "$st" -t "$SECS" -i "$SRC" -an -c copy "$W/w$i.mkv" || die "cut failed"
  "$FFMPEG" -v error -y -i "$W/w$i.mkv" $VF -c:v ffv1 -an "$W/w${i}_ref.mkv" || die "reference failed"
  # the source against itself: its own banding (CAMBI baseline)
  "$FFMPEG" -nostats -i "$W/w${i}_ref.mkv" -i "$W/w${i}_ref.mkv" -lavfi \
    "[0:v][1:v]libvmaf=n_threads=8:n_subsample=4:feature=name=cambi:log_fmt=json:log_path=$W/w${i}_src.json" \
    -f null - >/dev/null 2>&1
  for q in "${QS[@]}"; do
    "$FFMPEG" -v error -y -i "$W/w$i.mkv" -fps_mode cfr -r "$RATE" $VF \
      -c:v hevc_videotoolbox -q:v "$q" -tag:v hvc1 -an "$W/w${i}_q$q.mp4" || die "encode q$q failed"
    "$FFMPEG" -v error -i "$W/w${i}_q$q.mp4" -map 0:v -c copy -f hevc - 2>/dev/null | md5 > "$W/w${i}_q$q.md5"
    stat -f %z "$W/w${i}_q$q.mp4" > "$W/w${i}_q$q.bytes"
    cat > "$W/fg" <<EOF
[0:v]setpts=PTS-STARTPTS,split=2[a1][a2];[1:v]setpts=PTS-STARTPTS,split=2[b1][b2];
[a1][b1]libvmaf=n_threads=8:n_subsample=2:log_fmt=json:log_path=$W/w${i}_q$q.json:feature=name=cambi;
[a2][b2]libvmaf=n_threads=8:n_subsample=2:model=version=vmaf_v0.6.1neg:log_fmt=json:log_path=$W/w${i}_q${q}_neg.json
EOF
    "$FFMPEG" -nostats -i "$W/w${i}_q$q.mp4" -i "$W/w${i}_ref.mkv" -filter_complex_script "$W/fg" -f null - >/dev/null 2>&1 \
      || die "scoring q$q failed"
    printf ' q%s' "$q"
  done
  echo "$st" > "$W/w$i.start"; printf '\n'; i=$((i+1))
done

SLIPMAT_SRC_BYTES="$SB" "$PY" "$HERE/tools/compare.py" "$W" "$N" "$SECS" "$DUR" "$SRC" "${CROP:--}" "$SINFO" "$OUTD" "${QS[@]}" \
  | tee "$OUTD/table.txt" | tee "$LOGD/$(date +%H%M%S) COMPARE $(printf '%s' "$STEM" | cut -c1-120).log" \
  || die "summary failed"

# keep the raw scores (small) so any run can be re-summarized under new rules without
# re-encoding: python3 tools/compare.py <saved>/scores N SECS DUR SRC CROP SINFO OUTDIR q...
mkdir -p "$OUTD/scores" && cp "$W"/*.json "$W"/*.start "$W"/*.md5 "$W"/*.bytes "$OUTD/scores/" 2>/dev/null
printf '%s\n' "$N $SECS $DUR" "$SRC" "${CROP:--}" "$SINFO" "${QS[*]}" > "$OUTD/scores/run.txt"
# the eye check: the window where the dials differ most, zoomed 1:1 at its centre
WW=$(cat "$W/worst" 2>/dev/null || echo 0); LO=${QS[0]}; HI=${QS[${#QS[@]}-1]}
DIMS=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$W/w${WW}_ref.mkv")
FW=${DIMS%,*}; FH=${DIMS#*,}; RW=$(( FW<640 ? FW : 640 )); RH=$(( FH<360 ? FH : 360 ))
RX=$(( (FW-RW)/2 )); RY=$(( (FH-RH)/2 )); Z="crop=$RW:$RH:$RX:$RY"
L=""; for k in 0 1 2 3 4 5; do [ -f "$W/lab$k.png" ] && L="$L -i $W/lab$k.png"; done
if [ -n "$L" ]; then OV(){ printf '[%s][%s:v]overlay=8:8[%s]' "$1" "$2" "$3"; }; else OV(){ printf '[%s]null[%s]' "$1" "$3"; }; fi
cat > "$W/clip.fg" <<EOF
[0:v]setpts=PTS-STARTPTS,format=yuv420p,split=3[r0][r1][r2];
[1:v]setpts=PTS-STARTPTS,format=yuv420p,split=2[l0][l1];
[2:v]setpts=PTS-STARTPTS,format=yuv420p,split=2[h0][h1];
[r0]$Z[ro];[l0]$Z[lo];[h0]$Z[ho];
[l1][r1]blend=all_mode=difference,lutyuv=y=clip(val*6\,0\,255):u=128:v=128,$Z[ld];
[h1][r2]blend=all_mode=difference,lutyuv=y=clip(val*6\,0\,255):u=128:v=128,$Z[hd];
color=c=black:s=${RW}x${RH}:d=$SECS[bk];
$(OV ro 3 A);$(OV lo 4 B);$(OV ho 5 C);$(OV bk 6 D);$(OV ld 7 E);$(OV hd 8 F);
[A][B][C]hstack=3[top];[D][E][F]hstack=3[bot];[top][bot]vstack[out]
EOF
CLIP="$OUTD/compare q$LO vs q$HI.mp4"
if "$FFMPEG" -v error -y -i "$W/w${WW}_ref.mkv" -i "$W/w${WW}_q$LO.mp4" -i "$W/w${WW}_q$HI.mp4" $L \
     -filter_complex_script "$W/clip.fg" -map '[out]' -shortest -c:v libx264 -crf 10 -preset fast \
     -pix_fmt yuv420p -tag:v avc1 "$CLIP" 2>"$W/clip.err"; then
  printf '  clip    %s\n' "$CLIP"
  [ -z "$L" ] && printf '          (top: original · q%s · q%s — bottom: legend · damage q%s · damage q%s)\n' "$LO" "$HI" "$LO" "$HI"
  [ "$OPEN" = "1" ] && open -a "QuickTime Player" "$CLIP" 2>/dev/null
else
  printf '  ! clip failed (%s) — the numbers above stand\n' "$(tail -1 "$W/clip.err")"
fi
printf '  saved   %s/\n\n' "$OUTD"
