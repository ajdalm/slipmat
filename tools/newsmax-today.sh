#!/bin/bash
# slipmat newsmax — the day's Newsmax shows, one command.
#
#   slipmat newsmax                   read the shows, ask one line (how do you want them?), go
#   slipmat newsmax <picks>           the same with the answer given: `b` · `h` · `q q b h` · `1080,480`
#   slipmat newsmax list              newest episode + sizes per show, no rip
#   slipmat newsmax --here <picks>    rip in this window, one after another (no Terminal windows)
#
# NMX_DAILY in ~/.slipmat/config names the shows by their newsmaxtv.com/Shows/<slug>
# and each one's usual answer — pipe-separated `slug=answer`:
#   NMX_DAILY="Show-One=best|Show-Two=quick|Show-Three=360"
# NMX_HIGH_Q (default 45) is the dial `high` renders at: measured 11.2.26 on an hour of 1080 broadcast,
# q45 is the last dial under the source size; q50 lands at it, q55-q60 bloat 1.5-1.8x the source for
# under one just-noticeable difference.
#
# The answers, one for every show or one per show in order:
#   b  best    720p CFR re-encode — the overnight pick, the everyday size            [Enter]
#   h  high    native 1080p CFR re-encode at q<NMX_HIGH_Q> — sharper, a longer render
#   q  quick   480p direct copy, no re-encode — minutes; transcribe now, re-rip later
#   s  small   360p direct copy, no re-encode
#   a height (1080 720 480 360) · a row number from the sizes list · `h55` = high at that dial
#
# The newest episode of each show is read the way the engine's show door reads it
# (the show page's own listing call, then Newsmax's own service for the stream and
# the title). A show whose newest episode is already in the output folder is skipped
# and said so. Each rip opens in its own Terminal window (the launcher's kind: the
# window closes itself after a finished rip; `x` stops, `↓` steps a slow download
# down) so every show shows its own progress; `--here` runs them in this window one
# after another instead. Each rip is the engine as it always runs: the receipt, the
# run log, the name `<ROW> <m.d.yy> [NMX]`.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$HERE/engine/slipmat-video"
_envq="${NMX_HIGH_Q:-}"   # the environment outranks the config, as the engine's switches do
NMX_DAILY=""; NMX_SHOWS=""; NMX_HIGH_Q=""; OUTDIR="$HOME/SLIPMAT Downloads"
[ -f "$HOME/.slipmat/config" ] && . "$HOME/.slipmat/config"
OUTDIR="${OUTDIR%/}"; NMX_HIGH_Q="${_envq:-${NMX_HIGH_Q:-45}}"
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
ladder() { curl -s -m 20 "$1" 2>/dev/null | head -c 200000 | ladder_parse; }
ladder_parse() {   # stdin = a master playlist (pure; smoke-tested)
  grep -o 'RESOLUTION=[0-9]*x[0-9]*' | sed 's/.*x//' | sort -rn | uniq
}

# ---- the answers (pure; smoke-tested) -------------------------------------------------
# picks_parse "<line>" <nshows> → one answer per show, space-separated: best|high|quick|small|
# <height>|row<n>|high@<q>. A lone answer applies to every show; commas and spaces both
# separate; a short line = best for the rest; an unknown word reads as best.
pick_word() {
  case "$(lc "$1")" in
    ''|b|best) printf 'best' ;;
    h|high|hi|1080n|native) printf 'high' ;;
    h[0-9][0-9]|high[0-9][0-9]) printf 'high@%s' "$(printf '%s' "$1" | tr -dc 0-9)" ;;
    q|quick|fast) printf 'quick' ;;
    s|small) printf 'small' ;;
    [1-9]) printf 'row%s' "$1" ;;
    [1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) printf '%s' "$1" ;;
    *) printf 'best' ;;
  esac
}
picks_parse() {
  _l=$(printf '%s' "$1" | tr ',' ' ' | tr -s ' ')
  _n="$2"
  set -- $_l
  if [ $# -eq 0 ]; then _i=0; while [ "$_i" -lt "$_n" ]; do printf 'best '; _i=$((_i+1)); done; return 0; fi
  if [ $# -eq 1 ]; then _i=0; _w=$(pick_word "$1"); while [ "$_i" -lt "$_n" ]; do printf '%s ' "$_w"; _i=$((_i+1)); done; return 0; fi
  _i=0; for _p in "$@"; do _i=$((_i+1)); [ "$_i" -le "$_n" ] && printf '%s ' "$(pick_word "$_p")"; done
  while [ "$_i" -lt "$_n" ]; do printf 'best '; _i=$((_i+1)); done
}
# answer_cmd <answer> <ladder "1080 720 …"> → the engine's words after the URL, with any
# environment in front: `best` · `SLIPMAT_KEEP_NATIVE=1 SLIPMAT_Q=50 best` · `480 auto` (pure; smoke-tested)
answer_cmd() {
  _a="$1"; _lad="$2"
  case "$_a" in
    best) printf 'best' ;;
    high) printf 'SLIPMAT_KEEP_NATIVE=1 SLIPMAT_Q=%s best' "$NMX_HIGH_Q" ;;
    high@*) printf 'SLIPMAT_KEEP_NATIVE=1 SLIPMAT_Q=%s best' "${_a#high@}" ;;
    quick) printf '480 auto' ;;
    small) printf '360 auto' ;;
    row*)  _r="${_a#row}"; _h=$(printf '%s\n' $_lad | sed -n "${_r}p"); [ -n "$_h" ] || _h=$(printf '%s\n' $_lad | tail -1)
           if [ "$_h" = "$(printf '%s\n' $_lad | head -1)" ]; then printf 'best'; else printf '%s auto' "$_h"; fi ;;
    *)     printf '%s auto' "$_a" ;;
  esac
}
answer_words() {   # the plain words for the screen
  case "$1" in best) printf 'best · 720p re-encode' ;; high) printf 'high · 1080p native at q%s' "$NMX_HIGH_Q" ;; high@*) printf 'high · 1080p native at q%s' "${1#high@}" ;;
    quick) printf 'quick · 480p direct' ;; small) printf 'small · 360p direct' ;; row*) printf 'row %s' "${1#row}" ;; *) printf '%sp' "$1" ;; esac
}

case "${1:-}" in
  --parse-picks)  picks_parse "${2:-}" "${3:-4}"; exit 0 ;;      # smoke hooks (pure)
  --parse-ladder) ladder_parse; exit 0 ;;
  --answer-cmd)   answer_cmd "${2:-best}" "${3:-}"; exit 0 ;;
esac

WHERE="windows"; [ "${NMX_WINDOWS:-1}" = "0" ] && WHERE="here"
case "${1:-}" in --here) WHERE="here"; shift ;; esac
MODE="go"; PICKS="${*:-}"
case "${1:-}" in list) MODE="list" ;; esac
[ -n "$PY" ] || die "python3 is needed to read the show pages"
[ -n "$NMX_DAILY" ] || die "no shows set — put NMX_DAILY=\"Show-Slug=best|Other-Show=quick\" in ~/.slipmat/config (the slug is the one in newsmaxtv.com/Shows/<slug>)"
command -v osascript >/dev/null 2>&1 || WHERE="here"

# ---- read every show first ---------------------------------------------------------
SLUGS=""; USUAL=""; IDS=""; NAMES=""; LADDERS=""; HAVE=""; NSHOWS=0
say ""
say "${C_B}NEWSMAX TODAY${C_Z}"
_i=0
OLDIFS=$IFS; IFS='|'; set -- $NMX_DAILY; IFS=$OLDIFS
for _row in "$@"; do
  [ -n "$_row" ] || continue
  _slug="${_row%%=*}"; _usual="${_row#*=}"; [ "$_usual" = "$_row" ] && _usual="best"
  _usual=$(pick_word "$_usual")
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
  SLUGS="$SLUGS $_slug"; USUAL="$USUAL $_usual"; IDS="$IDS $_eid"; NSHOWS=$((NSHOWS+1))
  NAMES="$NAMES|${_name:-$_elabel}"; LADDERS="$LADDERS|$_lad"; HAVE="$HAVE $_have"
  _ladw=""; _k=0; for _h in $_lad; do _k=$((_k+1)); _ladw="$_ladw  ${C_B}$_k${C_Z}) ${_h}p"; done
  if [ "$_have" = "1" ]; then _tag="${C_G}already in the folder${C_Z}"
  else _tag="${C_D}usually $(answer_words "$_usual")${C_Z}"; fi
  say "  ${C_B}$_i)${C_Z} ${_name:-$_elabel}   $_tag"
  [ "$MODE" = "list" ] && say "     ${C_D}sizes${C_Z}$_ladw"
done
[ "$NSHOWS" -gt 0 ] || die "none of the shows answered"
[ "$MODE" = "list" ] && { say ""; exit 0; }

# ---- the one question ---------------------------------------------------------------
if [ -z "$PICKS" ] && [ -t 0 ]; then
  say ""
  say "${C_Q}How do you want them?${C_Z}  ${C_D}one answer for every show, or one per show in order (like: h b q q)${C_Z}"
  say "  ${C_B}b${C_Z}  best    720p CFR re-encode — the overnight pick                ${C_B}[Enter]${C_Z}"
  say "  ${C_B}h${C_Z}  high    native 1080p CFR re-encode at q$NMX_HIGH_Q — sharper, a longer render  ${C_D}(h55 = at that dial)${C_Z}"
  say "  ${C_B}q${C_Z}  quick   480p direct copy, no re-encode — minutes; transcribe now, re-rip later"
  say "  ${C_B}s${C_Z}  small   360p direct copy, no re-encode"
  say "  ${C_D}or a height (1080 720 480 360)  ·  Enter = each show's usual (the list above)${C_Z}"
  printf '%s%s%s ' "$C_Q" "answer" "$C_Z"
  IFS= read -r PICKS
fi
if [ -z "$PICKS" ]; then PICKSET="$USUAL"; else PICKSET=$(picks_parse "$PICKS" "$NSHOWS"); fi

# ---- go: a window per show, or here one after another --------------------------------
open_window() {   # $1 = the command line; the launcher's kind of window (SLIPMAT_WINDOW=1 closes itself after a finished rip)
  osascript - "$1" <<'AS' >/dev/null 2>&1
on run argv
  tell application "Terminal"
    activate
    do script "SLIPMAT_WINDOW=1 " & (item 1 of argv)
  end tell
end run
AS
}
_i=0; _ran=0; _skipped=0
say ""
for _slug in $SLUGS; do
  _i=$((_i+1))
  _eid=$(printf '%s' "$IDS" | awk -v n="$_i" '{print $n}')
  _have=$(printf '%s' "$HAVE" | awk -v n="$_i" '{print $n}')
  _name=$(printf '%s' "$NAMES" | cut -d'|' -f$((_i+1)))
  _lad=$(printf '%s' "$LADDERS" | cut -d'|' -f$((_i+1)))
  _a=$(printf '%s' "$PICKSET" | awk -v n="$_i" '{print $n}'); [ -n "$_a" ] || _a="best"
  if [ "$_have" = "1" ]; then _skipped=$((_skipped+1)); say "  ${C_D}$_i) $_name — already in the folder, skipped${C_Z}"; continue; fi
  _url="https://www.newsmaxtv.com/Shows/$_slug/vid/$_eid"
  _tail=$(answer_cmd "$_a" "$_lad")
  _env=""; _args="$_tail"
  case "$_tail" in *" best"|*" auto") case "$_tail" in SLIPMAT_*|SLIPMAT_Q=*) _env="${_tail% best}"; _args="best" ;; esac ;; esac
  if [ "$WHERE" = "windows" ]; then
    _cmd="$_env $(printf '%q' "$ENGINE") $(printf '%q' "$_url") $_args"
    open_window "${_cmd# }"
    say "  ${C_B}$_i)${C_Z} $_name — $(answer_words "$_a") · its window is open"
  else
    say ""
    say "${C_B}── $_i of $NSHOWS · $_name · $(answer_words "$_a") ──${C_Z}"
    env $_env "$ENGINE" "$_url" $_args
  fi
  _ran=$((_ran+1))
done
say ""
if [ "$WHERE" = "windows" ]; then say "${C_B}NEWSMAX TODAY${C_Z} — $_ran window(s) opened · $_skipped already there · each window closes itself when its rip is done (x stops it, ↓ steps a slow download down)"
else say "${C_B}NEWSMAX TODAY${C_Z} — $_ran ripped · $_skipped already there"; fi
# a menu-bar window (SLIPMAT_WINDOW=1) closes itself once the shows are off in their own windows
[ "${SLIPMAT_WINDOW:-0}" = "1" ] && [ "$WHERE" = "windows" ] && [ -t 0 ] && [ -f "$HERE/tools/window-close.sh" ] \
  && /bin/bash "$HERE/tools/window-close.sh" 45 "This window closes itself in 45 s — the shows run in their own windows"
exit 0
