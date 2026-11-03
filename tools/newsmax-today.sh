#!/bin/bash
# slipmat newsmax — the day's Newsmax shows, one command.
#
#   slipmat newsmax                   every show in NMX_DAILY, newest episode, its configured size
#   slipmat newsmax custom            list each show's sizes, take one line of picks, then rip
#   slipmat newsmax custom 1,2,4,3    the same with the picks given (one number = every show)
#   slipmat newsmax list              newest episode + sizes per show, no rip
#
# NMX_DAILY in ~/.slipmat/config names the shows by their newsmaxtv.com/Shows/<slug>
# and the size each one rips at — pipe-separated `slug=size`, size = best or a height:
#   NMX_DAILY="Show-One=best|Show-Two=720|Show-Three=360"
# The newest episode of each show is read the way the engine's show door reads it
# (the show page's own listing call, then Newsmax's own service for the stream and
# the title). A show whose newest episode is already in the output folder is skipped
# and said so; the rest rip one after another (Newsmax's CDN throttles parallel
# pulls — one at a time is the fastest total). Each rip is the engine as it always
# runs: the receipt, the run log, the name `<ROW> <m.d.yy> [NMX]`.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$HERE/engine/slipmat-video"
NMX_DAILY=""; NMX_SHOWS=""; OUTDIR="$HOME/SLIPMAT Downloads"
[ -f "$HOME/.slipmat/config" ] && . "$HOME/.slipmat/config"
OUTDIR="${OUTDIR%/}"
PY=$(command -v python3 2>/dev/null)
NMX_SHOWS_LEARNED="$HOME/.slipmat/nmx_shows_learned"
# the engine's own colors, so the screen reads as one tool
if [ -t 1 ]; then C_B=$'\033[1m'; C_D=$'\033[2m'; C_Q=$'\033[38;5;141m'; C_Y=$'\033[33m'; C_G=$'\033[32m'; C_R=$'\033[31m'; C_Z=$'\033[0m'
else C_B=""; C_D=""; C_Q=""; C_Y=""; C_G=""; C_R=""; C_Z=""; fi
say() { printf '%s\n' "$*"; }
die() { printf '%s✗ %s%s\n' "$C_R" "$*" "$C_Z" >&2; exit 1; }

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
show_rows() {   # the naming menu the engine uses: NMX_SHOWS + the learned list
  _r="$NMX_SHOWS"
  [ -s "$NMX_SHOWS_LEARNED" ] && _r="${_r:+$_r|}$(tr '\n' '|' < "$NMX_SHOWS_LEARNED" | sed 's/|*$//; s/^|*//')"
  printf '%s' "$_r"
}
show_match() {   # $1 = official title → the first menu row whose every word is in it
  _t=$(lc "$1")
  printf '%s\n' "$(show_rows)" | tr '|' '\n' | while IFS= read -r _row; do
    [ -n "$_row" ] || continue
    _all=1
    for _w in $(lc "$_row"); do case "$_t" in *"$_w"*) : ;; *) _all=0 ;; esac; done
    [ "$_all" = "1" ] && { printf '%s' "$_row"; break; }
  done
}
title_date() {   # "Show (10/08/26)" → 10.8.26
  printf '%s' "$1" | sed -n -E 's/.*\(([0-9]{1,2})\/([0-9]{1,2})\/([0-9]{2})\).*/\1.\2.\3/p' | sed 's/\.0\([0-9]\)/.\1/g; s/^0//'
}

# ---- reading one show -----------------------------------------------------------
# newest_episode <slug> → "<id>\t<label>" (the show page's listing call, newest first)
newest_episode() {
  _url="https://www.newsmaxtv.com/Shows/$1"
  _cat=$(curl -s -m 20 "$_url" 2>/dev/null | head -c 400000 | grep -o 'category_ids=[A-Za-z0-9]*' | head -1 | sed 's/category_ids=//')
  [ -n "$_cat" ] || return 1
  curl -s -m 20 "https://www.newsmaxtv.com/api/v1/_24iService/GetPlaylist?category_ids=$_cat" 2>/dev/null | head -c 2000000 | "$PY" -c '
import json,sys,re,html
raw=sys.stdin.read()
m=re.search(r"<string[^>]*>(.*)</string>", raw, re.S)
body=html.unescape(m.group(1)) if m else raw
try:
    d=json.loads(body)
    if isinstance(d,str): d=json.loads(d)
except Exception: raise SystemExit(1)
items=d.get("items",[]) if isinstance(d,dict) else d
items=[i for i in items if i.get("id") and not i.get("isHidden")]
items.sort(key=lambda i: i.get("createdAt") or 0, reverse=True)
if not items: raise SystemExit(1)
i=items[0]
print("%s\t%s" % (i["id"], (i.get("label") or i.get("seriesName") or "").replace("\t"," ").replace("\n"," ")))'
}
# episode_stream <id> → "<title>\t<master url>" (Newsmax's own service)
episode_stream() {
  curl -s -m 20 "https://nmxmam.nmax.tv/vodservice/?id=$1" 2>/dev/null | head -c 100000 | "$PY" -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit(1)
if isinstance(d,dict): d=[d]
if not d: raise SystemExit(1)
e=d[0]; src=e.get("source") or []
if isinstance(src,dict): src=[src]
u=next((s.get("src") for s in src if s.get("src")), "")
if not u: raise SystemExit(1)
print("%s\t%s" % ((e.get("title") or "").replace("\t"," ").replace("\n"," "), u))'
}
# ladder <master url> → the heights on offer, highest first, one per line
ladder() {
  curl -s -m 20 "$1" 2>/dev/null | head -c 200000 | ladder_parse
}
ladder_parse() {   # stdin = a master playlist (pure; smoke-tested)
  grep -o 'RESOLUTION=[0-9]*x[0-9]*' | sed 's/.*x//' | sort -rn | uniq
}

# ---- the picks line (pure; smoke-tested) -----------------------------------------
# picks_parse "<line>" <nshows> → one pick per show, space-separated; "" = best for all.
# A lone number applies to every show; commas and spaces both separate; a word
# that is not a number reads as best.
picks_parse() {
  _l=$(printf '%s' "$1" | tr ',' ' ' | tr -s ' ')
  _n="$NSHOWS"
  set -- $_l
  if [ $# -eq 0 ]; then return 0; fi
  if [ $# -eq 1 ]; then _i=0; while [ "$_i" -lt "$_n" ]; do printf '%s ' "$1"; _i=$((_i+1)); done; return 0; fi
  _i=0; for _p in "$@"; do _i=$((_i+1)); [ "$_i" -le "$_n" ] && printf '%s ' "$_p"; done
  while [ "$_i" -lt "$_n" ]; do printf 'best '; _i=$((_i+1)); done
}

case "${1:-}" in
  --parse-picks) NSHOWS="${3:-4}"; picks_parse "${2:-}"; exit 0 ;;      # smoke hooks (pure)
  --parse-ladder) ladder_parse; exit 0 ;;
esac

MODE="${1:-auto}"; PICKS="${2:-}"
case "$MODE" in auto|custom|list) ;; *) die "slipmat newsmax [custom [picks]] | list — not '$MODE'" ;; esac
[ -n "$PY" ] || die "python3 is needed to read the show pages"
[ -n "$NMX_DAILY" ] || die "no shows set — put NMX_DAILY=\"Show-Slug=best|Other-Show=360\" in ~/.slipmat/config (the slug is the one in newsmaxtv.com/Shows/<slug>)"

# ---- read every show first ---------------------------------------------------------
SLUGS=""; SIZES=""; IDS=""; LABELS=""; NAMES=""; LADDERS=""; HAVE=""; NSHOWS=0
say ""
say "${C_B}NEWSMAX TODAY${C_Z}"
_i=0
OLDIFS=$IFS; IFS='|'; set -- $NMX_DAILY; IFS=$OLDIFS
for _row in "$@"; do
  [ -n "$_row" ] || continue
  _slug="${_row%%=*}"; _size="${_row#*=}"; [ "$_size" = "$_row" ] && _size="best"
  _i=$((_i+1))
  _ep=$(newest_episode "$_slug") || { say "  ${C_Y}$_i) $_slug — no episode list answered; skipped${C_Z}"; continue; }
  _eid=$(printf '%s' "$_ep" | cut -f1); _elabel=$(printf '%s' "$_ep" | cut -f2)
  _st=$(episode_stream "$_eid") || { say "  ${C_Y}$_i) $_slug — Newsmax's service lists no stream for the newest episode ($_elabel); skipped${C_Z}"; continue; }
  _title=$(printf '%s' "$_st" | cut -f1); _src=$(printf '%s' "$_st" | cut -f2)
  _date=$(title_date "$_title")
  _rowname=$(show_match "$_title")
  _name=""; [ -n "$_rowname" ] && [ -n "$_date" ] && _name="$_rowname $_date [NMX]"
  _lad=$(ladder "$_src" | tr '\n' ' ')
  _have=0; [ -n "$_name" ] && [ -e "$OUTDIR/$_name.mp4" ] && _have=1
  SLUGS="$SLUGS $_slug"; SIZES="$SIZES $_size"; IDS="$IDS $_eid"; NSHOWS=$((NSHOWS+1))
  LABELS="$LABELS|$_elabel"; NAMES="$NAMES|${_name:-$_elabel}"; LADDERS="$LADDERS|$_lad"; HAVE="$HAVE $_have"
  _ladw=""; _k=0; for _h in $_lad; do _k=$((_k+1)); _ladw="$_ladw  ${C_B}$_k${C_Z}) ${_h}p"; done
  if [ "$_have" = "1" ]; then _tag="${C_G}already in the folder${C_Z}"
  else _tag="${C_D}→ $_size${C_Z}"; fi
  say "  ${C_B}$_i)${C_Z} ${_name:-$_elabel}   $_tag"
  [ "$MODE" != "auto" ] && say "     ${C_D}sizes${C_Z}$_ladw"
done
[ "$NSHOWS" -gt 0 ] || die "none of the shows answered"
[ "$MODE" = "list" ] && { say ""; exit 0; }

# ---- custom: one line of picks ---------------------------------------------------
if [ "$MODE" = "custom" ]; then
  if [ -z "$PICKS" ] && [ -t 0 ]; then
    say ""
    printf '%s%s%s %s[Enter = best for every show]%s  ' "$C_Q" "Which size for each show, in order? (like 1, 2, 4, 3)" "$C_Z" "$C_B" "$C_Z"
    IFS= read -r PICKS
  fi
  PICKSET=$(picks_parse "$PICKS")
fi

# ---- rip, one after another --------------------------------------------------------
_i=0; _ran=0; _skipped=0
for _slug in $SLUGS; do
  _i=$((_i+1))
  _size=$(printf '%s' "$SIZES" | awk -v n="$_i" '{print $n}')
  _eid=$(printf '%s' "$IDS" | awk -v n="$_i" '{print $n}')
  _have=$(printf '%s' "$HAVE" | awk -v n="$_i" '{print $n}')
  _name=$(printf '%s' "$NAMES" | cut -d'|' -f$((_i+1)))
  _lad=$(printf '%s' "$LADDERS" | cut -d'|' -f$((_i+1)))
  if [ "$_have" = "1" ]; then _skipped=$((_skipped+1)); continue; fi
  if [ "$MODE" = "custom" ]; then
    _pk=$(printf '%s' "${PICKSET:-}" | awk -v n="$_i" '{print $n}')
    case "$_pk" in
      ''|best) _size="best" ;;
      *[!0-9]*) _size="best" ;;
      *) _nl=$(printf '%s\n' $_lad | grep -c .)
         if [ "$_pk" -ge 1 ] && [ "$_pk" -le "$_nl" ]; then _size=$(printf '%s\n' $_lad | sed -n "${_pk}p")
         else _size=$(printf '%s\n' $_lad | tail -1); say "  ${C_Y}$_i) pick $_pk is past the list — taking the smallest, ${_size}p${C_Z}"; fi ;;
    esac
  fi
  say ""
  say "${C_B}── $_i of $NSHOWS · $_name · $_size ──${C_Z}"
  _url="https://www.newsmaxtv.com/Shows/$_slug/vid/$_eid"
  case "$_size" in
    best|max) "$ENGINE" "$_url" best ;;
    *)        "$ENGINE" "$_url" "$_size" auto ;;
  esac
  _ran=$((_ran+1))
done
say ""
say "${C_B}NEWSMAX TODAY${C_Z} — $_ran ripped · $_skipped already there"
