#!/bin/bash
# slipmat newsmax — the day's Newsmax shows, one command.
#
#   slipmat newsmax                   read the shows, ask one line (how do you want them?), go
#   slipmat newsmax <picks>           the same with the answer given: `b` · `h` · `q q b h` · `1080,480`
#   slipmat newsmax list              newest episode + sizes per show, no rip
#   slipmat newsmax --here <picks>    rip in this window, one after another (no Terminal windows)
#   slipmat newsmax <picks> --wait 3  keep watching up to 3 h for the shows whose episode today is due
#                                     but not posted yet (the default: NMX_WAIT_H, 3; 0 = no wait)
#
# "Today's episode" goes by each show's own rhythm, read from its episode list: the weekdays it
# posts and the time of day it usually posts. Before that time (the morning after, a weekend, a
# day the show is off) the newest episode IS the current one: it is ripped like any other, nothing
# is watched. A show is watched only when its usual posting time falls inside the watch.
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
title_date() {   # "Show (10/08/26)" → 10.8.26
  printf '%s' "$1" | sed -n -E 's/.*\(([0-9]{1,2})\/([0-9]{1,2})\/([0-9]{2})\).*/\1.\2.\3/p' | sed 's/\.0\([0-9]\)/.\1/g; s/^0//'
}
today_mdy() { date +%m.%d.%y | sed 's/\.0\([0-9]\)/.\1/g; s/^0//'; }   # the same shape: 11.4.26
have_name() {   # $1 = the file stem → 0 when the finished file OR a running rip's reservation exists
  [ -n "$1" ] && { [ -e "$OUTDIR/$1.mp4" ] || [ -e "$CAPDIR/$1.mp4.claim" ]; }
}
# wait_args "<args>" → "<hours>\t<the rest>": pulls `--wait [N]` / `--wait=N` out of the picks (pure; smoke-tested)
wait_args() {
  _w="${NMX_WAIT_H:-3}"; _rest=""; _grab=0
  for _a in $1; do
    if [ "$_grab" = "1" ]; then _grab=0; case "$_a" in [0-9]|[0-9][0-9]|[0-9].[0-9]*|[0-9][0-9].[0-9]*|.[0-9]*) _w="$_a"; continue ;; esac; fi
    case "$_a" in --wait=*) _w="${_a#--wait=}" ;; --wait) _grab=1 ;; --now|now) _w=0 ;; *) _rest="$_rest $_a" ;; esac
  done
  printf '%s\t%s' "$_w" "${_rest# }"
}

# due_rule <weekday 1-7> <minute now> <weekdays> <usual minute> <watch hours> → 1 when today's episode
# is due before the watch ends: today is one of the show's days and its usual time, with half an hour
# of room, falls before now + the watch (a watch that would end before the show usually posts is no
# watch). An unknown rhythm counts as every day at noon. (pure; smoke-tested)
due_rule() {
  _wd="$1"; _now="$2"; _days="${3:-1234567}"; _med="${4:-720}"; _wh="$5"
  case "$_days" in *"$_wd"*) : ;; *) printf 0; return 0 ;; esac
  awk -v n="$_now" -v m="$_med" -v w="$_wh" 'BEGIN{ print (w>0 && m+30 <= n+w*60) ? 1 : 0 }'
}
clock_of() {   # minute of day → 4:58pm
  [ -n "$1" ] || return 0
  _h=$(( $1 / 60 )); _m=$(( $1 % 60 )); _ap=am; [ "$_h" -ge 12 ] && _ap=pm; _h=$(( _h % 12 )); [ "$_h" = 0 ] && _h=12
  printf '%d:%02d%s' "$_h" "$_m" "$_ap"
}

# ---- reading one show -----------------------------------------------------------
# newest_episode <slug> → "<id>\t<label>\t<usual minute of day>\t<weekdays 1-7>" (the show page's
# listing call, newest first). The rhythm comes from the episodes posted on their own date: the
# median time of day they went up, and the weekdays they went up on (1 = Monday); empty when
# fewer than three episodes say it.
newest_episode() {
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
mins=[]; days=set()
for e in items[:20]:
    m2=re.search(r"\((\d{1,2})/(\d{1,2})/(\d{2})\)", e.get("label") or "")
    try: t=datetime.datetime.fromtimestamp(int(e.get("createdAt") or 0))
    except Exception: continue
    if not m2 or (t.month,t.day,t.year%100)!=tuple(int(x) for x in m2.groups()): continue
    mins.append(t.hour*60+t.minute); days.add(t.isoweekday())
mins.sort()
med=str(mins[len(mins)//2]) if len(mins)>=3 else ""
dd="".join(str(x) for x in sorted(days)) if len(mins)>=3 else ""
i=items[0]
print("%s\t%s\t%s\t%s" % (i["id"], (i.get("label") or i.get("seriesName") or "").replace("\t"," ").replace("\n"," "), med, dd))'
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
  --parse-wait)   wait_args "${2:-}"; exit 0 ;;
  --due)          due_rule "${2:-1}" "${3:-0}" "${4:-}" "${5:-}" "${6:-3}"; exit 0 ;;
esac

WHERE="windows"; [ "${NMX_WINDOWS:-1}" = "0" ] && WHERE="here"
case "${1:-}" in --here) WHERE="here"; shift ;; esac
MODE="go"; PICKS="${*:-}"
case "${1:-}" in list) MODE="list" ;; esac
_wa=$(wait_args "$PICKS"); WAIT_H=$(printf '%s' "$_wa" | cut -f1); PICKS=$(printf '%s' "$_wa" | cut -f2)
case "$WAIT_H" in ''|*[!0-9.]*) WAIT_H=3 ;; esac
[ "$(printf '%s' "$WAIT_H" | awk '{print ($1>0)?1:0}')" = "1" ] || WAIT_H=0
TODAY=$(today_mdy); WDAY=$(date +%u); NOWMIN=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
[ -n "$PY" ] || die "python3 is needed to read the show pages"
[ -n "$NMX_DAILY" ] || die "no shows set — put NMX_DAILY=\"Show-Slug=best|Other-Show=quick\" in ~/.slipmat/config (the slug is the one in newsmaxtv.com/Shows/<slug>)"
command -v osascript >/dev/null 2>&1 || WHERE="here"

# ---- read every show first ---------------------------------------------------------
SLUGS=""; USUAL=""; IDS=""; NAMES=""; LADDERS=""; HAVE=""; LATE=""; NSHOWS=0
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
  _med=$(printf '%s' "$_ep" | cut -f3); _days=$(printf '%s' "$_ep" | cut -f4)
  _st=$(episode_stream "$_eid") || { say "  ${C_Y}$_i) $_slug — Newsmax's service lists no stream for the newest episode ($_elabel); skipped${C_Z}"; continue; }
  _title=$(printf '%s' "$_st" | cut -f1); _src=$(printf '%s' "$_st" | cut -f2)
  _date=$(title_date "$_title")
  _rowname=$(show_match "$_title")
  _name=""; [ -n "$_rowname" ] && [ -n "$_date" ] && _name="$_rowname $_date [NMX]"
  _lad=$(ladder "$_src" | tr '\n' ' ')
  _have=0; have_name "$_name" && _have=1   # finished, or a window is ripping it right now
  [ "$_have" = "1" ] && [ ! -e "$OUTDIR/$_name.mp4" ] && _have=2   # 2 = a rip is running on it now
  # the newest episode is not today's AND today's is due inside the watch: late (the wait below watches
  # for it). Before its usual time (the morning after, a weekend) the newest one is simply the current one.
  _late=0; [ -n "$_date" ] && [ "$_date" != "$TODAY" ] && [ "$(due_rule "$WDAY" "$NOWMIN" "$_days" "$_med" "$WAIT_H")" = "1" ] && _late=1
  _when=""; [ -n "$_med" ] && _when="usually about $(clock_of "$_med")"
  SLUGS="$SLUGS $_slug"; USUAL="$USUAL $_usual"; IDS="$IDS $_eid"; NSHOWS=$((NSHOWS+1))
  NAMES="$NAMES|${_name:-$_elabel}"; LADDERS="$LADDERS|$_lad"; HAVE="$HAVE $_have"; LATE="$LATE $_late"
  _ladw=""; _k=0; for _h in $_lad; do _k=$((_k+1)); _ladw="$_ladw  ${C_B}$_k${C_Z}) ${_h}p"; done
  if [ "$_late" = "1" ]; then _tag="${C_Y}today's episode is not posted yet${C_Z}${_when:+ ${C_D}($_when)${C_Z}}"; [ "$_have" != "0" ] && _tag="$_tag ${C_D}(the $_date one is in the folder)${C_Z}"
  elif [ "$_have" = "2" ]; then _tag="${C_G}ripping now in its own window${C_Z}"
  elif [ "$_have" = "1" ]; then _tag="${C_G}already in the folder${C_Z}"
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
rip_one() {   # <n> <slug> <episode id> <name> <ladder> <answer> <clock or ""> — a window, or here
  _url="https://www.newsmaxtv.com/Shows/$2/vid/$3"
  _tail=$(answer_cmd "$6" "$5")
  _env=""; _args="$_tail"
  case "$_tail" in *" best"|*" auto") case "$_tail" in SLIPMAT_*|SLIPMAT_Q=*) _env="${_tail% best}"; _args="best" ;; esac ;; esac
  if [ "$WHERE" = "windows" ]; then
    _cmd="$_env $(printf '%q' "$ENGINE") $(printf '%q' "$_url") $_args"
    open_window "${_cmd# }"
    say "  ${C_B}$1)${C_Z} $4 — $(answer_words "$6") · its window is open${7:+ · $7}"
  else
    say ""
    say "${C_B}── $1 of $NSHOWS · $4 · $(answer_words "$6")${7:+ · $7} ──${C_Z}"
    env $_env "$ENGINE" "$_url" $_args
  fi
}
_i=0; _ran=0; _skipped=0; _waiting=""
say ""
for _slug in $SLUGS; do
  _i=$((_i+1))
  _eid=$(printf '%s' "$IDS" | awk -v n="$_i" '{print $n}')
  _have=$(printf '%s' "$HAVE" | awk -v n="$_i" '{print $n}')
  _name=$(printf '%s' "$NAMES" | cut -d'|' -f$((_i+1)))
  _lad=$(printf '%s' "$LADDERS" | cut -d'|' -f$((_i+1)))
  _a=$(printf '%s' "$PICKSET" | awk -v n="$_i" '{print $n}'); [ -n "$_a" ] || _a="best"
  _late=$(printf '%s' "$LATE" | awk -v n="$_i" '{print $n}')
  if [ "$_late" = "1" ]; then
    _waiting="$_waiting $_i"
    if [ "$_have" = "0" ]; then   # the newest one is not in the folder either: rip it now, and watch for today's
      say "  ${C_Y}$_i) $_slug — today's episode is not posted yet; ripping the $(printf '%s' "$_name" | sed -n -E 's/.* ([0-9.]+) \[NMX\]$/\1/p') one now and watching for today's${C_Z}"
      rip_one "$_i" "$_slug" "$_eid" "$_name" "$_lad" "$_a" ""; _ran=$((_ran+1))
    else say "  ${C_Y}$_i) $_slug — today's episode is not posted yet; watching for it${C_Z}"; fi
    continue
  fi
  if [ "$_have" = "2" ]; then _skipped=$((_skipped+1)); say "  ${C_D}$_i) $_name — ripping now in its own window, left alone${C_Z}"; continue; fi
  if [ "$_have" = "1" ]; then _skipped=$((_skipped+1)); say "  ${C_D}$_i) $_name — already in the folder, skipped${C_Z}"; continue; fi
  rip_one "$_i" "$_slug" "$_eid" "$_name" "$_lad" "$_a" ""
  _ran=$((_ran+1))
done
# ---- the wait: the shows not posted yet are read again every few minutes ------------------
# A show counts as posted the moment its newest episode carries today's date; it is ripped
# then with its own answer (its window opens, or it runs here). The watch ends when every
# show is in, or after NMX_WAIT_H hours (3), and says which never came. x ends the watch
# early (asked once); the rips already running are not touched.
_never=""; _late_n=0; _ended=0; _asked=0
if [ -n "$_waiting" ]; then
  _late_n=$(printf '%s' "$_waiting" | wc -w | tr -d ' ')
  _end=$(( $(date +%s) + $(printf '%s' "$WAIT_H" | awk '{printf "%d", $1*3600}') ))
  _every="${NMX_WAIT_EVERY:-600}"; case "$_every" in ''|0|*[!0-9]*) _every=600 ;; esac   # whole seconds, never a tight loop on the site
  say ""
  say "${C_B}WATCHING${C_Z} for $_late_n show(s) not posted yet — reading the site every $([ "$_every" -ge 60 ] && printf '%s min' "$((_every/60))" || printf '%s s' "$_every") until $(date -r "$_end" +%-I:%M%p | tr A-Z a-z), ripping each when it drops · ${C_B}x${C_Z} ends the watch"
  _asked=0
  while [ -n "$_waiting" ] && [ "$(date +%s)" -lt "$_end" ]; do
    _k=""
    if [ -t 0 ]; then IFS= read -r -t "$_every" -n 1 _k 2>/dev/null; else sleep "$_every"; fi
    case "$_k" in
      x|X) if [ "$_asked" = "0" ]; then _asked=1; say "  ${C_Q}end the watch?${C_Z}  ${C_B}x${C_Z} ends it · any other key keeps watching"; continue
           else say "  watch ended — $(printf '%s' "$_waiting" | wc -w | tr -d ' ') show(s) left unwatched"; break; fi ;;
      '') : ;;
      *) _asked=0; continue ;;
    esac
    _asked=0
    _still=""
    for _i in $_waiting; do
      _slug=$(printf '%s' "$SLUGS" | awk -v n="$_i" '{print $n}')
      _a=$(printf '%s' "$PICKSET" | awk -v n="$_i" '{print $n}'); [ -n "$_a" ] || _a="best"
      _ep=$(newest_episode "$_slug") || { _still="$_still $_i"; continue; }
      _eid=$(printf '%s' "$_ep" | cut -f1); _elabel=$(printf '%s' "$_ep" | cut -f2)
      _st=$(episode_stream "$_eid") || { _still="$_still $_i"; continue; }
      _title=$(printf '%s' "$_st" | cut -f1); _src=$(printf '%s' "$_st" | cut -f2)
      _date=$(title_date "$_title")
      [ "$_date" = "$TODAY" ] || { _still="$_still $_i"; continue; }
      _rowname=$(show_match "$_title"); _name=""; [ -n "$_rowname" ] && _name="$_rowname $_date [NMX]"
      _clock=$(date +%-I:%M%p | tr A-Z a-z)
      if have_name "$_name"; then say "  ${C_D}$_i) $_name — posted, and already in the folder · $_clock${C_Z}"; continue; fi
      _lad=$(ladder "$_src" | tr '\n' ' ')
      say "  ${C_G}$_i) ${_name:-$_elabel} — posted · $_clock${C_Z}"
      rip_one "$_i" "$_slug" "$_eid" "${_name:-$_elabel}" "$_lad" "$_a" "$_clock"
      _ran=$((_ran+1))
    done
    _waiting="${_still# }"
  done
  for _i in $_waiting; do _never="$_never $(printf '%s' "$SLUGS" | awk -v n="$_i" '{print $n}')"; done
  [ "$_asked" = "1" ] && [ -n "$_never" ] && _ended=1
fi
say ""
_w=""; [ "$_late_n" -gt 0 ] && _w=" · $((_late_n - $(printf '%s' "$_never" | wc -w | tr -d ' '))) picked up while watching"
if [ "${_ended:-0}" = "1" ]; then _w="$_w · watch ended early, still not posted:${_never}"
elif [ -n "$_never" ]; then _w="$_w · never posted in the ${WAIT_H} h:${_never}"; fi
if [ "$WHERE" = "windows" ]; then say "${C_B}NEWSMAX TODAY${C_Z} — $_ran window(s) opened · $_skipped already there$_w · each window closes itself when its rip is done (x stops it, ↓ steps a slow download down)"
else say "${C_B}NEWSMAX TODAY${C_Z} — $_ran ripped · $_skipped already there$_w"; fi
# a menu-bar window (SLIPMAT_WINDOW=1) closes itself once the shows are off in their own windows
[ "${SLIPMAT_WINDOW:-0}" = "1" ] && [ "$WHERE" = "windows" ] && [ -t 0 ] && [ -f "$HERE/tools/window-close.sh" ] \
  && /bin/bash "$HERE/tools/window-close.sh" 45 "This window closes itself in 45 s — the shows run in their own windows"
exit 0
