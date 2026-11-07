#!/bin/bash
# slipmat newsmax — the Newsmax shows, one command: which day, then how.
#
#   slipmat newsmax                      the overview, then two questions: which day · how do you want them
#   slipmat newsmax today [picks]        today's episodes (the shows not posted yet are watched for)
#   slipmat newsmax yesterday [picks]    the last episode before today's (Friday's on a Monday)
#   slipmat newsmax both [picks]         yesterday's and today's
#   slipmat newsmax back 7 [picks]       every episode of today and the 7 days before, numbered; picks like `2h 3 7q`
#   slipmat newsmax list                 the overview and each show's recent episodes, no rip
#   slipmat newsmax --here ...           rip in this window, one after another (no Terminal windows)
#   slipmat newsmax ... --wait 2         watch up to 2 h for today's shows not posted yet (NMX_WAIT_H, 3; 0 = no wait)
#
# NMX_DAILY in ~/.slipmat/config names the shows by their newsmaxtv.com/Shows/<slug>
# and each one's usual answer — pipe-separated `slug=answer`:
#   NMX_DAILY="Show-One=best|Show-Two=quick|Show-Three=360"
# NMX_HIGH_Q (default 45) is the dial `high` renders at: measured 11.2.26 on an hour of 1080 broadcast,
# q45 is the last dial under the source size; q50 lands at it, q55-q60 bloat 1.5-1.8x the source for
# under one just-noticeable difference.
#
# The answers (how), one for every row or one per row in order:
#   b  best    720p CFR re-encode — the overnight pick, the everyday size            [Enter]
#   h  high    native 1080p CFR re-encode at q<NMX_HIGH_Q> — sharper, a longer render
#   q  quick   480p direct copy, no re-encode — minutes; transcribe now, re-rip later
#   s  small   360p direct copy, no re-encode
#   a height (1080 720 480 360) · a row number from the sizes list · `h55` = high at that dial
#
# Each show's episode list is read once (the show page's own listing call, every episode
# it lists, newest first); the stream and the title come from Newsmax's own service when
# a rip starts. An episode already in the output folder, or ripping in another window, is
# said so and left alone. Today's episode goes by the show's own rhythm, read from the
# same list: the weekdays it posts and the time of day it usually goes up. A show not
# posted yet whose usual time falls inside the watch is watched for; one whose usual time
# is hours off is said so and left for later. Each rip opens in its own Terminal window
# (the launcher's kind: the window closes itself after a finished rip; `x` stops, `↓`
# steps a slow download down); `--here` runs them in this window one after another.
# Each rip is the engine as it always runs: the receipt, the run log, the name
# `<ROW> <m.d.yy> [NMX]`.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$HERE/engine/slipmat-video"
_envq="${NMX_HIGH_Q:-}"   # the environment outranks the config, as the engine's switches do
_envw="${NMX_WAIT_H:-}"
NMX_DAILY=""; NMX_SHOWS=""; NMX_HIGH_Q=""; NMX_WAIT_H=""; OUTDIR="$HOME/SLIPMAT Downloads"
[ -f "$HOME/.slipmat/config" ] && . "$HOME/.slipmat/config"
OUTDIR="${OUTDIR%/}"; NMX_HIGH_Q="${_envq:-${NMX_HIGH_Q:-45}}"; NMX_WAIT_H="${_envw:-${NMX_WAIT_H:-3}}"
CAPDIR="$OUTDIR/_in progress"   # the engine's reservations (.mp4.claim) and growing files live here
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
have_name() {   # $1 = the file stem → 0 when the finished file OR a running rip's reservation exists
  [ -n "$1" ] && { [ -e "$OUTDIR/$1.mp4" ] || [ -e "$CAPDIR/$1.mp4.claim" ]; }
}
have_state() {   # $1 = the file stem → 0 none · 1 in the folder · 2 ripping now
  if [ -n "$1" ] && [ -e "$OUTDIR/$1.mp4" ]; then printf 1
  elif [ -n "$1" ] && [ -e "$CAPDIR/$1.mp4.claim" ]; then printf 2
  else printf 0; fi
}
clock_of() {   # minute of day → 4:58pm
  [ -n "$1" ] || return 0
  _h=$(( $1 / 60 )); _m=$(( $1 % 60 )); _ap=am; [ "$_h" -ge 12 ] && _ap=pm; _h=$(( _h % 12 )); [ "$_h" = 0 ] && _h=12
  printf '%d:%02d%s' "$_h" "$_m" "$_ap"
}

# ---- the words on the line (pure; smoke-tested) ------------------------------------------
# wait_args "<args>" → "<hours>\t<the rest>": pulls `--wait [N]` / `--wait=N` / `now` out of the line
wait_args() {
  _w="${NMX_WAIT_H:-3}"; _rest=""; _grab=0
  for _a in $1; do
    if [ "$_grab" = "1" ]; then _grab=0; case "$_a" in [0-9]|[0-9][0-9]|[0-9].[0-9]*|[0-9][0-9].[0-9]*|.[0-9]*) _w="$_a"; continue ;; esac; fi
    case "$_a" in --wait=*) _w="${_a#--wait=}" ;; --wait) _grab=1 ;; --now|now) _w=0 ;; *) _rest="$_rest $_a" ;; esac
  done
  printf '%s\t%s' "$_w" "${_rest# }"
}
# day_args "<args>" → "<day>\t<days back>\t<the rest>": the day word leads the line
#   today|t · yesterday|y · both|b (only as the FIRST word) · back N / custom N · nothing = ask
day_args() {
  _d=""; _n=""; _rest=""; _grab=0; _first=1
  for _a in $1; do
    if [ "$_grab" = "1" ]; then _grab=0; case "$_a" in [1-9]|[1-9][0-9]) _n="$_a"; continue ;; esac; fi
    if [ "$_first" = "1" ]; then
      _first=0
      case "$(lc "$_a")" in
        today|t) _d="today"; continue ;; yesterday|y) _d="yesterday"; continue ;; both) _d="both"; continue ;;
        back|custom|c) _d="back"; _grab=1; continue ;;
      esac
    fi
    _rest="$_rest $_a"
  done
  [ "$_d" = "back" ] && [ -z "$_n" ] && _n=7
  printf '%s\t%s\t%s' "$_d" "$_n" "${_rest# }"
}
# due_rule <weekday 1-7> <minute now> <weekdays> <usual minute> <watch hours> → 1 when today's episode
# is due before the watch ends: today is one of the show's days and its usual time, with half an hour
# of room, falls before now + the watch (a watch that would end before the show usually posts is no
# watch). An unknown rhythm counts as every day at noon.
due_rule() {
  _wd="$1"; _now="$2"; _days="${3:-1234567}"; _med="${4:-720}"; _wh="$5"
  case "$_days" in *"$_wd"*) : ;; *) printf 0; return 0 ;; esac
  awk -v n="$_now" -v m="$_med" -v w="$_wh" 'BEGIN{ print (w>0 && m+30 <= n+w*60) ? 1 : 0 }'
}

# ---- the answers (pure; smoke-tested) -------------------------------------------------
# picks_parse "<line>" <nrows> → one answer per row, space-separated: best|high|quick|small|
# <height>|row<n>|high@<q>. A lone answer applies to every row; commas and spaces both
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
# custom_picks "<line>" <nrows> → one answer per numbered row, `-` = not chosen: `2h 3 7q` picks
# rows 2 (high), 3 (its usual, `u`), 7 (quick); `all` / `all h` = every row; a number alone = its usual;
# `2-5` = rows 2 to 5; an unknown number is ignored. (pure; smoke-tested)
custom_picks() {
  _l=$(printf '%s' "$1" | tr ',' ' ' | tr -s ' '); _n="$2"
  _out=""; _i=0; while [ "$_i" -lt "$_n" ]; do _out="$_out -"; _i=$((_i+1)); done
  set -- $_l
  if [ "${1:-}" = "all" ] || [ "${1:-}" = "a" ]; then
    _w=$(pick_word "${2:-u}"); [ -z "${2:-}" ] && _w="u"
    _out=""; _i=0; while [ "$_i" -lt "$_n" ]; do _out="$_out $_w"; _i=$((_i+1)); done
    printf '%s' "${_out# }"; return 0
  fi
  for _p in "$@"; do
    _num=$(printf '%s' "$_p" | sed -E 's/^([0-9]+(-[0-9]+)?).*/\1/'); _how="${_p#$_num}"
    case "$_num" in ''|*[!0-9-]*) continue ;; esac
    _w="u"; [ -n "$_how" ] && _w=$(pick_word "$_how")
    case "$_num" in *-*) _from="${_num%-*}"; _to="${_num#*-}" ;; *) _from="$_num"; _to="$_num" ;; esac
    _k="$_from"; while [ "$_k" -le "$_to" ] 2>/dev/null; do
      if [ "$_k" -ge 1 ] && [ "$_k" -le "$_n" ]; then _out=$(printf '%s' "$_out" | awk -v n="$_k" -v w="$_w" '{ $n = w; print }'); fi
      _k=$((_k+1))
    done
  done
  printf '%s' "${_out# }"
}
# answer_cmd <answer> <ladder "1080 720 …"> → the engine's words after the URL, with any
# environment in front: `best` · `SLIPMAT_KEEP_NATIVE=1 SLIPMAT_Q=50 best` · `480 auto`
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

# ---- reading one show -----------------------------------------------------------
# show_list <slug> → every episode the show page lists, newest first, one per line:
#   <id> \t <m.d.yy> \t <days before today> \t <label>
# with the show's rhythm first: `rhythm \t <usual minute of day> \t <weekdays 1-7>` — the
# median time of day and the weekdays of the episodes posted on their own date (empty when
# fewer than three say it). The date is the one in the label; the posting day when the
# label carries none.
show_list() {
  _url="https://www.newsmaxtv.com/Shows/$1"
  _cat=$(curl -s -m 20 "$_url" 2>/dev/null | head -c 400000 | grep -o 'category_ids=[A-Za-z0-9]*' | head -1 | sed 's/category_ids=//')
  [ -n "$_cat" ] || return 1
  curl -s -m 20 "https://www.newsmaxtv.com/api/v1/_24iService/GetPlaylist?category_ids=$_cat" 2>/dev/null | head -c 2000000 | "$PY" -c '
import json,sys,re,html,datetime
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
today=datetime.date.today()
mins=[]; days=set(); rows=[]
for e in items:
    label=(e.get("label") or e.get("seriesName") or "").replace("\t"," ").replace("\n"," ")
    m2=re.search(r"\((\d{1,2})/(\d{1,2})/(\d{2})\)", label)
    try: t=datetime.datetime.fromtimestamp(int(e.get("createdAt") or 0))
    except Exception: t=None
    if m2:
        mo,da,yr=(int(x) for x in m2.groups()); d0=datetime.date(2000+yr,mo,da)
    elif t: d0=t.date()
    else: continue
    if t and t.date()==d0 and len(mins)<20:
        mins.append(t.hour*60+t.minute); days.add(t.isoweekday())
    rows.append("%s\t%d.%d.%02d\t%d\t%s" % (e["id"], d0.month, d0.day, d0.year%100, (today-d0).days, label))
mins.sort()
med=str(mins[len(mins)//2]) if len(mins)>=3 else ""
dd="".join(str(x) for x in sorted(days)) if len(mins)>=3 else ""
print("rhythm\t%s\t%s" % (med, dd))
print("\n".join(rows))'
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

case "${1:-}" in
  --parse-picks)  picks_parse "${2:-}" "${3:-4}"; exit 0 ;;      # smoke hooks (pure)
  --custom-picks) custom_picks "${2:-}" "${3:-8}"; exit 0 ;;
  --parse-ladder) ladder_parse; exit 0 ;;
  --answer-cmd)   answer_cmd "${2:-best}" "${3:-}"; exit 0 ;;
  --parse-wait)   wait_args "${2:-}"; exit 0 ;;
  --parse-day)    day_args "${2:-}"; exit 0 ;;
  --due)          due_rule "${2:-1}" "${3:-0}" "${4:-}" "${5:-}" "${6:-3}"; exit 0 ;;
esac

WHERE="windows"; [ "${NMX_WINDOWS:-1}" = "0" ] && WHERE="here"
case "${1:-}" in --here) WHERE="here"; shift ;; esac
MODE="go"; LINE="${*:-}"
_wa=$(wait_args "$LINE"); WAIT_H=$(printf '%s' "$_wa" | cut -f1); LINE=$(printf '%s' "$_wa" | cut -f2)
case "$WAIT_H" in ''|*[!0-9.]*) WAIT_H=3 ;; esac
[ "$(printf '%s' "$WAIT_H" | awk '{print ($1>0)?1:0}')" = "1" ] || WAIT_H=0
_da=$(day_args "$LINE"); DAY=$(printf '%s' "$_da" | cut -f1); BACK=$(printf '%s' "$_da" | cut -f2); PICKS=$(printf '%s' "$_da" | cut -f3)
case "$PICKS" in list|list\ *) MODE="list"; PICKS="${PICKS#list}"; PICKS="${PICKS# }" ;; esac
TODAY_MDY=$(date +%-m.%-d.%y); TODAY_WD=$(date +%u); NOWMIN=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
[ -n "$PY" ] || die "python3 is needed to read the show pages"
[ -n "$NMX_DAILY" ] || die "no shows set — put NMX_DAILY=\"Show-Slug=best|Other-Show=quick\" in ~/.slipmat/config (the slug is the one in newsmaxtv.com/Shows/<slug>)"
command -v osascript >/dev/null 2>&1 || WHERE="here"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/slipmat-newsmax.XXXXXX") || die "no scratch folder"
trap 'rm -rf "$WORK"' EXIT

# ---- read every show's list once ------------------------------------------------------
# $WORK/show.<i>   the episodes (show_list without its rhythm line)
# SLUGS / USUAL / ROWNAME / MED / DAYS — one entry per show, by its number
SLUGS=""; NSHOWS=0
say ""
say "${C_B}NEWSMAX${C_Z}  $(date '+%A %-m.%-d.%y · %-I:%M%p' | sed 's/AM$/am/; s/PM$/pm/')"
OLDIFS=$IFS; IFS='|'; set -- $NMX_DAILY; IFS=$OLDIFS
for _row in "$@"; do
  [ -n "$_row" ] || continue
  _slug="${_row%%=*}"; _usual="${_row#*=}"; [ "$_usual" = "$_row" ] && _usual="best"
  _i=$((NSHOWS+1))
  if ! show_list "$_slug" > "$WORK/list.$_i" 2>/dev/null || [ ! -s "$WORK/list.$_i" ]; then
    say "  ${C_Y}$_slug — no episode list answered; skipped${C_Z}"; continue
  fi
  NSHOWS=$_i; SLUGS="$SLUGS $_slug"
  _rh=$(head -1 "$WORK/list.$_i"); sed '1d' "$WORK/list.$_i" > "$WORK/show.$_i"
  printf '%s' "$(printf '%s' "$_rh" | cut -f2)" > "$WORK/med.$_i"; printf '%s' "$(printf '%s' "$_rh" | cut -f3)" > "$WORK/days.$_i"
  printf '%s' "$(pick_word "$_usual")" > "$WORK/usual.$_i"
  printf '%s' "$(show_match "$(head -1 "$WORK/show.$_i" | cut -f4)")" > "$WORK/rowname.$_i"
done
[ "$NSHOWS" -gt 0 ] || die "none of the shows answered"
show_var() { cat "$WORK/$1.$2" 2>/dev/null; }   # show_var usual 2
# ep_line <show n> <days back exactly | "before"> → the episode line (today = 0; "before" = the newest older than today)
ep_line() {
  if [ "$2" = "before" ]; then awk -F'\t' '$3 >= 1 { print; exit }' "$WORK/show.$1"
  else awk -F'\t' -v d="$2" '$3 == d { print; exit }' "$WORK/show.$1"; fi
}
ep_name() {   # <show n> <episode line> → "<ROW> <m.d.yy> [NMX]" (the label when no menu row matches)
  _rn=$(show_var rowname "$1"); _d=$(printf '%s' "$2" | cut -f2)
  if [ -n "$_rn" ]; then printf '%s %s [NMX]' "$_rn" "$_d"; else printf '%s' "$2" | cut -f4; fi
}
state_words() {   # <have 0|1|2> → the words after a name
  case "$1" in 1) printf '%s' "${C_G}in the folder${C_Z}" ;; 2) printf '%s' "${C_G}ripping now in its own window${C_Z}" ;; *) : ;; esac
}
# today_state <show n> → "posted" | "late" (not posted, due inside the watch) | "off" (not posted, not due)
today_state() {
  [ -n "$(ep_line "$1" 0)" ] && { printf 'posted'; return 0; }
  if [ "$(due_rule "$TODAY_WD" "$NOWMIN" "$(show_var days "$1")" "$(show_var med "$1")" "$WAIT_H")" = "1" ]; then printf 'late'; else printf 'off'; fi
}

# ---- the overview: every show, today and the one before ---------------------------------
_i=0; _posted=0; _late=0
for _slug in $SLUGS; do
  _i=$((_i+1))
  _rn=$(show_var rowname "$_i"); [ -n "$_rn" ] || _rn="$_slug"
  _t=$(ep_line "$_i" 0); _y=$(ep_line "$_i" before)
  _ts=$(today_state "$_i"); _med=$(show_var med "$_i")
  case "$_ts" in
    posted) _posted=$((_posted+1)); _tw="today ${C_G}$(printf '%s' "$_t" | cut -f2)${C_Z} $(state_words "$(have_state "$(ep_name "$_i" "$_t")")")" ;;
    late)   _late=$((_late+1)); _tw="today ${C_Y}not posted yet${C_Z}${_med:+ ${C_D}(usually about $(clock_of "$_med"))${C_Z}}" ;;
    *)      _tw="today ${C_D}not posted yet${_med:+ (usually about $(clock_of "$_med"))}${C_Z}" ;;
  esac
  if [ -n "$_y" ]; then _yl="yesterday"; [ "$(printf '%s' "$_y" | cut -f3)" = "1" ] || _yl="last"
    _yw="$_yl ${C_B}$(printf '%s' "$_y" | cut -f2)${C_Z} $(state_words "$(have_state "$(ep_name "$_i" "$_y")")")"
  else _yw="${C_D}nothing before today${C_Z}"; fi
  say "  $(printf '%-12s' "$_rn")  $_tw   ·   $_yw"
  if [ "$MODE" = "list" ]; then
    say "     ${C_D}recent: $(awk -F'\t' 'NR<=8 { printf "%s%s", (NR>1?" · ":""), $2 }' "$WORK/show.$_i")${C_Z}"
  fi
done
[ "$MODE" = "list" ] && { say ""; exit 0; }

# ---- which day -----------------------------------------------------------------------
ask_day() {
  say ""
  say "${C_Q}Which day?${C_Z}"
  say "  ${C_B}t${C_Z}  today's        the episodes dated today — the ones not posted yet are watched for   ${C_B}[Enter]${C_Z}"
  say "  ${C_B}y${C_Z}  yesterday's    the last episode before today's (Friday's on a Monday)"
  say "  ${C_B}b${C_Z}  both           yesterday's and today's"
  say "  ${C_B}c${C_Z}  custom         today and a number of days before it, every episode listed — pick by hand"
  printf '%s%s%s ' "$C_Q" "answer" "$C_Z"
  IFS= read -r _ans
  case "$(lc "$_ans")" in ''|t|today) DAY="today" ;; y|yesterday) DAY="yesterday" ;; b|both) DAY="both" ;;
    c|custom|back) DAY="back"; printf '%s%s%s ' "$C_Q" "How many days back?" "$C_Z ${C_D}[7]${C_Z}"; IFS= read -r _n
       case "$_n" in ''|*[!0-9]*) _n=7 ;; esac; [ "$_n" -ge 1 ] || _n=7; BACK="$_n" ;;
    *) DAY="today" ;;
  esac
}
if [ -z "$DAY" ]; then
  if [ -t 0 ]; then ask_day; else DAY="today"; fi
fi

# ---- the rows: one per episode to rip ------------------------------------------------------
# $WORK/rows: <show n> \t <episode id> \t <name> \t <date> \t <state: rip|have|running|late|off>
build_rows() {
  : > "$WORK/rows"
  _i=0
  for _slug in $SLUGS; do
    _i=$((_i+1))
    case "$DAY" in
      today|both|yesterday)
        if [ "$DAY" != "today" ]; then
          _y=$(ep_line "$_i" before)
          if [ -n "$_y" ]; then _nm=$(ep_name "$_i" "$_y"); _st=rip; case "$(have_state "$_nm")" in 1) _st=have ;; 2) _st=running ;; esac
            printf '%s\t%s\t%s\t%s\t%s\n' "$_i" "$(printf '%s' "$_y" | cut -f1)" "$_nm" "$(printf '%s' "$_y" | cut -f2)" "$_st" >> "$WORK/rows"; fi
        fi
        if [ "$DAY" != "yesterday" ]; then
          _t=$(ep_line "$_i" 0)
          if [ -n "$_t" ]; then _nm=$(ep_name "$_i" "$_t"); _st=rip; case "$(have_state "$_nm")" in 1) _st=have ;; 2) _st=running ;; esac
            printf '%s\t%s\t%s\t%s\t%s\n' "$_i" "$(printf '%s' "$_t" | cut -f1)" "$_nm" "$(printf '%s' "$_t" | cut -f2)" "$_st" >> "$WORK/rows"
          else printf '%s\t\t%s\t%s\t%s\n' "$_i" "$(show_var rowname "$_i") $TODAY_MDY [NMX]" "$TODAY_MDY" "$(today_state "$_i")" >> "$WORK/rows"; fi
        fi ;;
      back)
        awk -F'\t' -v n="$BACK" '$3 <= n' "$WORK/show.$_i" | while IFS=$'\t' read -r _id _d _ago _label; do
          _nm=$(ep_name "$_i" "$(printf '%s\t%s\t%s\t%s' "$_id" "$_d" "$_ago" "$_label")"); _st=rip; case "$(have_state "$_nm")" in 1) _st=have ;; 2) _st=running ;; esac
          printf '%s\t%s\t%s\t%s\t%s\n' "$_i" "$_id" "$_nm" "$_d" "$_st" >> "$WORK/rows"
        done ;;
    esac
  done
}
build_rows
NROWS=$(wc -l < "$WORK/rows" | tr -d ' ')
row_field() { sed -n "${1}p" "$WORK/rows" | cut -f"$2"; }   # row_field 3 5 → row 3's state

# a day with nothing to rip is said so, and the question comes back (a tty) — never a silent exit
_rippable=$(awk -F'\t' '$5 == "rip" || $5 == "late"' "$WORK/rows" | wc -l | tr -d ' ')
while [ "$_rippable" = "0" ]; do
  say ""
  case "$DAY" in
    today) if [ "$_posted" = "0" ]; then say "  ${C_Y}none of today's episodes are up yet, and none is due inside the watch — ${C_B}y${C_Z}${C_Y} = yesterday's${C_Z}"
           else say "  ${C_Y}today's episodes are all in the folder (or ripping now)${C_Z}"; fi ;;
    yesterday) say "  ${C_Y}yesterday's episodes are all in the folder (or ripping now)${C_Z}" ;;
    both) say "  ${C_Y}nothing of yesterday's or today's is left to rip${C_Z}" ;;
    back) say "  ${C_Y}every episode of today and the $BACK days before is in the folder (or ripping now)${C_Z}" ;;
  esac
  [ -t 0 ] || exit 0
  ask_day; build_rows; NROWS=$(wc -l < "$WORK/rows" | tr -d ' ')
  _rippable=$(awk -F'\t' '$5 == "rip" || $5 == "late"' "$WORK/rows" | wc -l | tr -d ' ')
done

# ---- the rows on screen, then how ----------------------------------------------------------
say ""
case "$DAY" in today) say "${C_B}TODAY'S${C_Z}" ;; yesterday) say "${C_B}YESTERDAY'S${C_Z}" ;; both) say "${C_B}YESTERDAY'S AND TODAY'S${C_Z}" ;; back) say "${C_B}TODAY AND THE $BACK DAY$([ "$BACK" = 1 ] || printf S) BEFORE${C_Z}" ;; esac
_k=0
while [ "$_k" -lt "$NROWS" ]; do
  _k=$((_k+1)); _n=$(row_field "$_k" 1); _nm=$(row_field "$_k" 3); _st=$(row_field "$_k" 5); _med=$(show_var med "$_n")
  case "$_st" in
    rip)     _tag="${C_D}usually $(answer_words "$(show_var usual "$_n")")${C_Z}" ;;
    have)    _tag="${C_G}in the folder${C_Z}" ;;
    running) _tag="${C_G}ripping now in its own window${C_Z}" ;;
    late)    _tag="${C_Y}not posted yet${_med:+ (usually about $(clock_of "$_med"))} — watched for${C_Z}" ;;
    *)       _tag="${C_D}not posted yet${_med:+ (usually about $(clock_of "$_med"))} — outside the watch, left for later${C_Z}" ;;
  esac
  say "  ${C_B}$(printf '%2s' "$_k"))${C_Z} $_nm   $_tag"
done

ask_how() {
  say ""
  if [ "$DAY" = "back" ]; then
    say "${C_Q}Which ones?${C_Z}  ${C_D}numbers, with how glued on (like: 2h 3 7q) · 2-5 = a span · all · all h${C_Z}"
  else
    say "${C_Q}How do you want them?${C_Z}  ${C_D}one answer for every row, or one per row in order (like: h b q q)${C_Z}"
  fi
  say "  ${C_B}b${C_Z}  best    720p CFR re-encode — the overnight pick                $([ "$DAY" = "back" ] || printf '%s[Enter]%s' "$C_B" "$C_Z")"
  say "  ${C_B}h${C_Z}  high    native 1080p CFR re-encode at q$NMX_HIGH_Q — sharper, a longer render  ${C_D}(h55 = at that dial)${C_Z}"
  say "  ${C_B}q${C_Z}  quick   480p direct copy, no re-encode — minutes; transcribe now, re-rip later"
  say "  ${C_B}s${C_Z}  small   360p direct copy, no re-encode"
  if [ "$DAY" = "back" ]; then say "  ${C_D}a number alone = that show's usual  ·  Enter = every one not in the folder, each at its usual${C_Z}"
  else say "  ${C_D}or a height (1080 720 480 360)  ·  Enter = each show's usual (the list above)${C_Z}"; fi
  printf '%s%s%s ' "$C_Q" "answer" "$C_Z"
  IFS= read -r PICKS
}
[ -z "$PICKS" ] && [ -t 0 ] && ask_how
# PICKSET: one answer per row; `u` = the show's usual; `-` = not chosen (custom only)
if [ "$DAY" = "back" ]; then
  if [ -z "$PICKS" ]; then PICKSET=$(custom_picks "all" "$NROWS"); else PICKSET=$(custom_picks "$PICKS" "$NROWS"); fi
else
  if [ -z "$PICKS" ]; then PICKSET=""; _k=0; while [ "$_k" -lt "$NROWS" ]; do PICKSET="$PICKSET u"; _k=$((_k+1)); done; PICKSET="${PICKSET# }"
  else PICKSET=$(picks_parse "$PICKS" "$NROWS"); fi
fi
row_pick() {   # <row k> → its answer, the usual resolved
  _p=$(printf '%s' "$PICKSET" | awk -v n="$1" '{print $n}'); [ -n "$_p" ] || _p="u"
  [ "$_p" = "u" ] && _p=$(show_var usual "$(row_field "$1" 1)")
  printf '%s' "${_p:-best}"
}

# ---- go: a window per row, or here one after another --------------------------------
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
rip_one() {   # <k> <show n> <episode id> <name> <answer> <clock or ""> — a window, or here
  _slug=$(printf '%s' "$SLUGS" | awk -v n="$2" '{print $n}')
  _url="https://www.newsmaxtv.com/Shows/$_slug/vid/$3"
  _lad=""; case "$5" in row*) _st=$(episode_stream "$3") && _lad=$(ladder "$(printf '%s' "$_st" | cut -f2)" | tr '\n' ' ') ;; esac
  _tail=$(answer_cmd "$5" "$_lad")
  _env=""; _args="$_tail"
  case "$_tail" in *" best"|*" auto") case "$_tail" in SLIPMAT_*|SLIPMAT_Q=*) _env="${_tail% best}"; _args="best" ;; esac ;; esac
  if [ "$WHERE" = "windows" ]; then
    _cmd="$_env $(printf '%q' "$ENGINE") $(printf '%q' "$_url") $_args"
    open_window "${_cmd# }"
    say "  ${C_B}$1)${C_Z} $4 — $(answer_words "$5") · its window is open${6:+ · $6}"
  else
    say ""
    say "${C_B}── $1 of $NROWS · $4 · $(answer_words "$5")${6:+ · $6} ──${C_Z}"
    env $_env "$ENGINE" "$_url" $_args
  fi
}
_ran=0; _skipped=0; _waiting=""; _k=0
say ""
while [ "$_k" -lt "$NROWS" ]; do
  _k=$((_k+1)); _n=$(row_field "$_k" 1); _eid=$(row_field "$_k" 2); _nm=$(row_field "$_k" 3); _st=$(row_field "$_k" 5)
  _a=$(row_pick "$_k")
  case "$_st" in
    late)    _waiting="$_waiting $_k"; say "  ${C_Y}$_k) $(show_var rowname "$_n") — not posted yet; watching for it${C_Z}" ;;
    off)     say "  ${C_D}$_k) $(show_var rowname "$_n") — not posted yet, usually about $(clock_of "$(show_var med "$_n")"); left for later${C_Z}" ;;
    running) _skipped=$((_skipped+1)); say "  ${C_D}$_k) $_nm — ripping now in its own window, left alone${C_Z}" ;;
    have)    _skipped=$((_skipped+1)); say "  ${C_D}$_k) $_nm — already in the folder, skipped${C_Z}" ;;
    *)       if [ "$_a" = "-" ]; then say "  ${C_D}$_k) $_nm — not picked${C_Z}"; continue; fi
             rip_one "$_k" "$_n" "$_eid" "$_nm" "$_a" ""; _ran=$((_ran+1)) ;;
  esac
done
# ---- the wait: today's shows not posted yet are read again every few minutes ---------------
# A show counts as posted the moment its list carries an episode dated today; it is ripped
# then with its own answer (its window opens, or it runs here). The watch ends when every
# show is in, or after NMX_WAIT_H hours (3), and says which never came. x ends the watch
# early (asked once); the rips already running are not touched.
_never=""; _never_n=0; _late_n=0; _ended=0; _asked=0
if [ -n "$_waiting" ]; then
  _late_n=$(printf '%s' "$_waiting" | wc -w | tr -d ' ')
  _end=$(( $(date +%s) + $(printf '%s' "$WAIT_H" | awk '{printf "%d", $1*3600}') ))
  _every="${NMX_WAIT_EVERY:-600}"; case "$_every" in ''|0|*[!0-9]*) _every=600 ;; esac   # whole seconds, never a tight loop on the site
  say ""
  say "${C_B}WATCHING${C_Z} for $_late_n show(s) not posted yet — reading the site every $([ "$_every" -ge 60 ] && printf '%s min' "$((_every/60))" || printf '%s s' "$_every") until $(date -r "$_end" +%-I:%M%p | tr A-Z a-z), ripping each when it drops · ${C_B}x${C_Z} ends the watch"
  while [ -n "$_waiting" ] && [ "$(date +%s)" -lt "$_end" ]; do
    _key=""
    if [ -t 0 ]; then IFS= read -r -t "$_every" -n 1 _key 2>/dev/null; else sleep "$_every"; fi
    case "$_key" in
      x|X) if [ "$_asked" = "0" ]; then _asked=1; say "  ${C_Q}end the watch?${C_Z}  ${C_B}x${C_Z} ends it · any other key keeps watching"; continue
           else say "  watch ended — $(printf '%s' "$_waiting" | wc -w | tr -d ' ') show(s) left unwatched"; break; fi ;;
      '') : ;;
      *) _asked=0; continue ;;
    esac
    _asked=0
    _still=""
    for _k in $_waiting; do
      _n=$(row_field "$_k" 1); _slug=$(printf '%s' "$SLUGS" | awk -v n="$_n" '{print $n}'); _a=$(row_pick "$_k")
      show_list "$_slug" 2>/dev/null | sed '1d' > "$WORK/again.$_n" || { _still="$_still $_k"; continue; }
      _t=$(awk -F'\t' '$3 == 0 { print; exit }' "$WORK/again.$_n")
      [ -n "$_t" ] || { _still="$_still $_k"; continue; }
      _nm=$(ep_name "$_n" "$_t"); _eid=$(printf '%s' "$_t" | cut -f1)
      _clock=$(date +%-I:%M%p | tr A-Z a-z)
      if have_name "$_nm"; then say "  ${C_D}$_k) $_nm — posted, and already in the folder · $_clock${C_Z}"; continue; fi
      say "  ${C_G}$_k) $_nm — posted · $_clock${C_Z}"
      rip_one "$_k" "$_n" "$_eid" "$_nm" "$_a" "$_clock"
      _ran=$((_ran+1))
    done
    _waiting="${_still# }"
  done
  _never_n=0; for _k in $_waiting; do _never="$_never $(show_var rowname "$(row_field "$_k" 1)")"; _never_n=$((_never_n+1)); done
  [ "$_asked" = "1" ] && [ -n "$_never" ] && _ended=1
fi
say ""
_w=""; [ "$_late_n" -gt 0 ] && _w=" · $((_late_n - _never_n)) picked up while watching"
if [ "${_ended:-0}" = "1" ]; then _w="$_w · watch ended early, still not posted:${_never}"
elif [ -n "$_never" ]; then _w="$_w · never posted in the ${WAIT_H} h:${_never}"; fi
if [ "$WHERE" = "windows" ]; then say "${C_B}NEWSMAX${C_Z} — $_ran window(s) opened · $_skipped already there$_w · each window closes itself when its rip is done (x stops it, ↓ steps a slow download down)"
else say "${C_B}NEWSMAX${C_Z} — $_ran ripped · $_skipped already there$_w"; fi
# a menu-bar window (SLIPMAT_WINDOW=1) closes itself once the shows are off in their own windows
[ "${SLIPMAT_WINDOW:-0}" = "1" ] && [ "$WHERE" = "windows" ] && [ -t 0 ] && [ -f "$HERE/tools/window-close.sh" ] \
  && /bin/bash "$HERE/tools/window-close.sh" 45 "This window closes itself in 45 s — the shows run in their own windows"
exit 0
