#!/bin/bash
# slipmat newsmax — the Newsmax shows, one command: which day, then how.
#
#   slipmat newsmax                      the overview, then two questions: which day · how do you want them
#   slipmat newsmax today [picks]        today's episodes (the shows not posted yet are watched for)
#   slipmat newsmax yesterday [picks]    the last episode before today's (Friday's on a Monday)
#   slipmat newsmax both [picks]         yesterday's and today's
#   slipmat newsmax back 7 [picks]       every episode of today and the 7 days before, numbered; picks like `2h 3 7q`
#   slipmat newsmax list                 the overview and each show's recent episodes, no rip
#   slipmat newsmax help                 every word this command knows; nothing read, nothing ripped
#   ... again                            rip an episode even when it is already in the folder
#   ... --here                           rip in this window, one after another (no Terminal windows)
#   ... --wait 2                         watch up to 2 h for today's shows not posted yet (NMX_WAIT_H, 3; now = no watch)
#
# EVERY word on the line is checked before a show page is read. A word this command does
# not know (a typo, a flag from another tool) stops it there: nothing read, no window
# opened, exit 2. A run nobody is there to answer never guesses a pick from a stray word.
#
# NMX_DAILY in ~/.slipmat/config names the shows by their newsmaxtv.com/Shows/<slug>
# and each one's usual answer — pipe-separated `slug=answer`:
#   NMX_DAILY="Show-One=best|Show-Two=quick|Show-Three=360"
# NMX_HIGH_Q (default 45) is the dial `high` renders at: measured 11.2.26 on an hour of 1080 broadcast,
# q45 is the last dial under the source size; q50 lands at it, q55-q60 bloat 1.5-1.8x the source for
# under one just-noticeable difference.
#
# The answers (how), one for every row or one per row in order (a short line = the usual for the rest):
#   b  best    720p CFR re-encode — the overnight pick, the everyday size
#   h  high    native 1080p CFR re-encode at q<NMX_HIGH_Q> — sharper, a longer render (`h55` = at that dial)
#   q  quick   480p direct copy, no re-encode — minutes; transcribe now, re-rip later
#   s  small   360p direct copy, no re-encode
#   u  usual   the show's own answer from NMX_DAILY                                   [Enter]
#   a height (720 480 360); 1080 reads as high — a plain 1080 rip of this source lands at 720
#
# Each show's episode list is read once (the show page's own listing call, every episode
# it lists, newest first; the shows are read side by side); the stream and the title come
# from Newsmax's own service when a rip starts. An episode already in the output folder,
# ripping in another window, or started by another run of this command a moment ago is
# said so and left alone (`again` rips one that is in the folder: the engine names the
# second copy by its size). A name reserved by a rip whose engine is gone is cleared and
# said. Today's episode goes by the show's own rhythm, read from the same list: the
# weekdays it posts and the time of day it usually goes up. A show not posted yet whose
# usual time falls inside the watch is watched for; one whose usual time is hours off is
# said so and left for later. Each rip opens in its own Terminal window (the launcher's
# kind: the window closes itself after a finished rip; `x` stops, `↓` steps a slow
# download down); `--here` runs them in this window one after another. Each rip is the
# engine as it always runs: the receipt, the run log, the name `<ROW> <m.d.yy> [NMX]`.
#
# Exit: 0 = everything asked for was started (or was already there) · 1 = a show did not
# answer, a window would not open, or a rip run here did not finish · 2 = a word on the
# line was not understood (nothing started).
set -u
set -f   # no word on the line is ever a file pattern
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$HERE/engine/slipmat-video"
_envq="${NMX_HIGH_Q:-}"   # the environment outranks the config, as the engine's switches do
_envw="${NMX_WAIT_H:-}"
NMX_DAILY=""; NMX_SHOWS=""; NMX_HIGH_Q=""; NMX_WAIT_H=""; OUTDIR="$HOME/SLIPMAT Downloads"
[ -f "$HOME/.slipmat/config" ] && . "$HOME/.slipmat/config"
OUTDIR="${OUTDIR%/}"; NMX_HIGH_Q="${_envq:-${NMX_HIGH_Q:-45}}"; NMX_WAIT_H="${_envw:-${NMX_WAIT_H:-3}}"
case "$NMX_HIGH_Q" in [1-9][0-9]) : ;; *) NMX_HIGH_Q=45 ;; esac
CAPDIR="$OUTDIR/_in progress"   # the engine's reservations (.mp4.claim) and growing files live here
WORKROOT="$HOME/.slipmat/work"  # the engine's scratch root: each run's vr_<time>_<pid>/claims names its reservations
STARTED="$HOME/.slipmat/nmx-started"   # one empty file per episode this command started in the last minutes
PY=$(command -v python3 2>/dev/null)
NMX_SHOWS_LEARNED="$HOME/.slipmat/nmx_shows_learned"
# the engine's own colors, so the screen reads as one tool
if [ -t 1 ]; then C_B=$'\033[1m'; C_D=$'\033[2m'; C_Q=$'\033[1;38;5;141m'; C_Y=$'\033[33m'; C_G=$'\033[32m'; C_R=$'\033[31m'; C_Z=$'\033[0m'
else C_B=""; C_D=""; C_Q=""; C_Y=""; C_G=""; C_R=""; C_Z=""; fi
say() { printf '%s\n' "$*"; }
die() { printf '%s✗ %s%s\n' "$C_R" "$*" "$C_Z" >&2; exit 1; }
plural() { if [ "$1" = "1" ]; then printf '%s %s' "$1" "$2"; else printf '%s %s' "$1" "$3"; fi; }   # plural 4 window windows

usage() {
  cat <<USAGE

${C_B}slipmat newsmax${C_Z} — the Newsmax shows in NMX_DAILY (~/.slipmat/config), a window per show

  slipmat newsmax               the overview, then two questions: which day · how
  slipmat newsmax today         today's episodes, each show at its usual
  slipmat newsmax yesterday     the last episode before today's (Friday's on a Monday)
  slipmat newsmax both          yesterday's and today's
  slipmat newsmax back 7        today and the 7 days before, every episode numbered, picked by hand
  slipmat newsmax list          only look: what is posted, what is in the folder
  slipmat newsmax help          this screen

${C_B}how${C_Z}, after the day — one answer for every row, or one per row in order (like: h b q q)
  b  best    720p re-encode, the everyday size
  h  high    native 1080p at q$NMX_HIGH_Q (h55 = at that dial) — sharper, a longer render
  q  quick   480p direct copy, minutes
  s  small   360p direct copy
  u  usual   the show's own answer from NMX_DAILY (what a short line leaves the rest at)
  a height   720 480 360 (1080 = high)
  after back N the picks are row numbers:  2h 3 7q  ·  2-5  ·  2:480  ·  all  ·  all h

${C_B}more words${C_Z}, anywhere on the line
  again      rip an episode even when it is already in the folder (the second copy carries its size)
  now        no watch for the shows not posted yet
  --wait 2   watch for them up to 2 hours (the usual: $NMX_WAIT_H)
  --here     rip in this window, one after another

A word this command does not know stops it before anything is read or ripped.

USAGE
}

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
# claim_orphaned <claim path> → 0 only when a scratch folder names this reservation and the engine
# that wrote it is gone (killed, a power loss: its exit never ran, so the name stayed reserved).
# No scratch folder naming it = nobody can tell = the reservation stands.
claim_orphaned() {
  _named=0
  find "$WORKROOT" -mindepth 2 -maxdepth 2 -name claims -path '*/vr_*' 2>/dev/null > "${WORK:-/dev/null}.ledgers" 2>/dev/null || return 1
  while IFS= read -r _led; do
    grep -qxF -- "$1" "$_led" 2>/dev/null || continue
    _named=1; _dir=$(dirname "$_led"); _pid="${_dir##*_}"
    case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
    if kill -0 "$_pid" 2>/dev/null; then
      case "$(ps -p "$_pid" -o command= 2>/dev/null)" in *slipmat-video*) return 1 ;; esac
    fi
  done < "${WORK:-/dev/null}.ledgers"
  [ "$_named" = "1" ]
}
# the start marks: an episode this command started is marked for 3 minutes, the gap between a
# window opening and its engine reserving the name — a second run in that gap leaves it alone.
mark_ok() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; return 0; }   # an episode id fit to be a file name
started_fresh() {   # $1 = episode id → 0 when a run of this command started it in the last 3 minutes
  mark_ok "$1" || return 1
  [ -n "$(find "${STARTED:?}/$1" -maxdepth 0 -type f -mmin -3 2>/dev/null)" ]
}
start_mark() {   # $1 = episode id → 0 = this run starts it · 1 = another run took it a moment ago
  mark_ok "$1" || return 0
  mkdir -p "${STARTED:?}" 2>/dev/null || return 0
  ( set -C; : > "${STARTED:?}/$1" ) 2>/dev/null && return 0
  started_fresh "$1" && return 1
  rm -f "${STARTED:?}/$1" 2>/dev/null
  ( set -C; : > "${STARTED:?}/$1" ) 2>/dev/null
}
start_unmark() { mark_ok "$1" || return 0; rm -f "${STARTED:?}/$1" 2>/dev/null; return 0; }
# have_state <file stem> [<episode id>] → 0 none · 1 in the folder · 2 ripping now · 3 started a moment ago
# (a reservation whose engine is gone is cleared here and noted for the screen)
have_state() {
  if [ -n "$1" ] && [ -e "$OUTDIR/$1.mp4" ]; then printf 1; return 0; fi
  if [ -n "$1" ] && [ -e "$CAPDIR/$1.mp4.claim" ]; then
    if [ -n "${WORK:-}" ] && [ -f "$CAPDIR/$1.mp4.claim" ] && [ ! -s "$CAPDIR/$1.mp4.claim" ] && claim_orphaned "$CAPDIR/$1.mp4.claim"; then
      rm -f "${CAPDIR:?}/$1.mp4.claim" 2>/dev/null
      grep -qxF -- "$1" "$WORK/cleared" 2>/dev/null || printf '%s\n' "$1" >> "$WORK/cleared"
    else printf 2; return 0; fi
  fi
  if started_fresh "${2:-}"; then printf 3; return 0; fi
  printf 0
}
clock_of() {   # minute of day → 4:58pm
  [ -n "$1" ] || return 0
  _h=$(( $1 / 60 )); _m=$(( $1 % 60 )); _ap=am; [ "$_h" -ge 12 ] && _ap=pm; _h=$(( _h % 12 )); [ "$_h" = 0 ] && _h=12
  printf '%d:%02d%s' "$_h" "$_m" "$_ap"
}

# ---- the answers (pure; smoke-tested) -------------------------------------------------
# pick_word <word> → best|high|high@<q>|quick|small|u|<height>, or NOTHING for a word that is no answer.
# A height above 720 is `high`: the engine brings a plain 1080 rip of this source down to 720, so the
# only 1080 file there is to have is the native one.
pick_word() {
  _pw=$(lc "$1")
  case "$_pw" in
    b|best) printf 'best' ;;
    h|high|hi|1080n|native) printf 'high' ;;
    h[2-9][0-9]|high[2-9][0-9]) printf 'high@%s' "$(printf '%s' "$_pw" | tr -dc 0-9)" ;;
    q|quick|fast) printf 'quick' ;;
    s|small) printf 'small' ;;
    u|usual) printf 'u' ;;
    [1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) if [ "$_pw" -gt 720 ]; then printf 'high'; else printf '%s' "$_pw"; fi ;;
    *) : ;;
  esac
}
# picks_check <day|back> "<picks>" → NOTHING when every word fits that day's grammar, else one sentence
picks_check() {
  _g="$1"; set -- $(printf '%s' "$2" | tr ',' ' ')
  if [ "$_g" = "back" ]; then
    case "$(lc "${1:-}")" in all|a)
      [ $# -le 2 ] || { printf 'after "all" comes one answer at most (all · all h)'; return 0; }
      [ -z "${2:-}" ] || [ -n "$(pick_word "$2")" ] || printf '"%s" is not an answer — the answers are b h q s u or a height' "$2"
      return 0 ;;
    esac
    for _p in "$@"; do
      _num=$(printf '%s' "$_p" | sed -E 's/^([0-9]+(-[0-9]+)?).*/\1/')
      case "$_num" in ''|*[!0-9-]*) printf '"%s" is not a row pick — after back N the picks are row numbers, the answer glued on (2h 3 7q · 2-5 · all · all h)' "$_p"; return 0 ;; esac
      _how="${_p#$_num}"; _how="${_how#[:=]}"
      [ -z "$_how" ] || [ -n "$(pick_word "$_how")" ] || { printf '"%s": "%s" is not an answer — the answers are b h q s u or a height' "$_p" "$_how"; return 0; }
    done
    return 0
  fi
  for _p in "$@"; do
    [ -n "$(pick_word "$_p")" ] && continue
    case "$(lc "$_p")" in
      [0-9]|[0-9][0-9]|[0-9]*-[0-9]*|[0-9]*[a-z]|[0-9]*[:=]*|all|a) printf '"%s" picks a row, and rows are picked only after back N (like: back 7 2h 3) — here the answers are b h q s u or a height' "$_p" ;;
      *) printf '"%s" is not a word this command knows' "$_p" ;;
    esac
    return 0
  done
}
# picks_parse "<line>" <nrows> → one answer per row, space-separated. Nothing = the usual (`u`) for
# every row; a lone answer applies to every row; a short line = the usual for the rest; commas and
# spaces both separate. More answers than rows → `!many <count>` (the caller refuses the line).
picks_parse() {
  _n="$2"; set -- $(printf '%s' "$1" | tr ',' ' ')
  if [ $# -gt "$_n" ] && [ $# -gt 1 ]; then printf '!many %s' "$#"; return 0; fi
  if [ $# -eq 1 ]; then _i=0; _w=$(pick_word "$1"); while [ "$_i" -lt "$_n" ]; do printf '%s ' "${_w:-u}"; _i=$((_i+1)); done; return 0; fi
  _i=0; for _p in "$@"; do _i=$((_i+1)); _w=$(pick_word "$_p"); printf '%s ' "${_w:-u}"; done
  while [ "$_i" -lt "$_n" ]; do printf 'u '; _i=$((_i+1)); done
}
# custom_picks "<line>" <nrows> → one answer per numbered row, `-` = not chosen: `2h 3 7q` picks
# rows 2 (high), 3 (its usual, `u`), 7 (quick); `2:480` = row 2 at 480; `all` / `all h` = every row;
# a number alone = its usual; `2-5` = rows 2 to 5; a number that is no row picks nothing.
custom_picks() {
  _n="$2"
  _out=""; _i=0; while [ "$_i" -lt "$_n" ]; do _out="$_out -"; _i=$((_i+1)); done
  set -- $(printf '%s' "$1" | tr ',' ' ')
  case "$(lc "${1:-}")" in all|a)
    _w="u"; [ -n "${2:-}" ] && _w=$(pick_word "$2"); _w="${_w:-u}"
    _out=""; _i=0; while [ "$_i" -lt "$_n" ]; do _out="$_out $_w"; _i=$((_i+1)); done
    printf '%s' "${_out# }"; return 0 ;;
  esac
  for _p in "$@"; do
    _num=$(printf '%s' "$_p" | sed -E 's/^([0-9]+(-[0-9]+)?).*/\1/'); _how="${_p#$_num}"; _how="${_how#[:=]}"
    case "$_num" in ''|*[!0-9-]*) continue ;; esac
    _w="u"; [ -n "$_how" ] && _w=$(pick_word "$_how"); _w="${_w:-u}"
    case "$_num" in *-*) _from="${_num%-*}"; _to="${_num#*-}" ;; *) _from="$_num"; _to="$_num" ;; esac
    case "$_from$_to" in ''|*[!0-9]*) continue ;; esac
    [ "${#_from}" -le 4 ] && [ "${#_to}" -le 4 ] || continue
    [ "$_to" -le "$_n" ] || _to="$_n"
    _k="$_from"; while [ "$_k" -le "$_to" ]; do
      if [ "$_k" -ge 1 ] && [ "$_k" -le "$_n" ]; then _out=$(printf '%s' "$_out" | awk -v n="$_k" -v w="$_w" '{ $n = w; print }'); fi
      _k=$((_k+1))
    done
  done
  printf '%s' "${_out# }"
}
# answer_cmd <answer> → the engine's words after the URL, with any environment in front:
# `best` · `SLIPMAT_KEEP_NATIVE=1 SLIPMAT_Q=50 best` · `480 auto`
answer_cmd() {
  case "$1" in
    best) printf 'best' ;;
    high) printf 'SLIPMAT_KEEP_NATIVE=1 SLIPMAT_Q=%s best' "$NMX_HIGH_Q" ;;
    high@*) printf 'SLIPMAT_KEEP_NATIVE=1 SLIPMAT_Q=%s best' "${1#high@}" ;;
    quick) printf '480 auto' ;;
    small) printf '360 auto' ;;
    [1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) printf '%s auto' "$1" ;;
    *) printf 'best' ;;
  esac
}
answer_words() {   # the plain words for the screen
  case "$1" in best) printf 'best · 720p re-encode' ;; high) printf 'high · 1080p native at q%s' "$NMX_HIGH_Q" ;; high@*) printf 'high · 1080p native at q%s' "${1#high@}" ;;
    quick) printf 'quick · 480p direct' ;; small) printf 'small · 360p direct' ;; *) printf '%sp' "$1" ;; esac
}

# ---- the words on the line (pure; smoke-tested) ------------------------------------------
is_hours() { case "$1" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac; awk -v h="$1" 'BEGIN{ exit !(h+0 <= 24) }'; }
# parse_line "<every word after `newsmax`>" → ONE tab-separated line:
#   ok \t <go|list|help> \t <here|-> \t <watch hours|-> \t <today|yesterday|both|back|-> \t <days back|-> \t <again 0|1> \t <picks>
#   err \t <one sentence>
# Words in any order and any case; commas separate like spaces. A day word: today|t ·
# yesterday|y · both · back N / custom N / c (N = 1-99, 7 when left out). `b` is always
# best, never both. Everything that is not a known word must be a pick that fits the day's
# grammar; anything else is an error — a typo never turns into a rip.
parse_line() {
  _mode="go"; _where=""; _wait=""; _day=""; _back=""; _again=0; _picks=""; _need=""
  for _a in $(printf '%s' "$1" | tr ',\t' '  '); do
    case "$(lc "$_a")" in help|-h|--help|-\?|--usage) printf 'ok\thelp\t-\t-\t-\t-\t0\t'; return 0 ;; esac
  done
  for _a in $(printf '%s' "$1" | tr ',\t' '  '); do
    _lw=$(lc "$_a")
    if [ "$_need" = "wait" ]; then _need=""
      if is_hours "$_lw"; then _wait="$_lw"; continue; fi
      printf 'err\t--wait needs a number of hours after it (like: --wait 2), not "%s"' "$_a"; return 0
    fi
    if [ "$_need" = "back" ]; then _need=""
      case "$_lw" in [1-9]|[1-9][0-9]) _back="$_lw"; continue ;; esac
    fi
    _nd=""
    case "$_lw" in
      list|--list) _mode="list" ;;
      --here|here) _where="here" ;;
      --wait) _need="wait" ;;
      --wait=*) if is_hours "${_lw#--wait=}"; then _wait="${_lw#--wait=}"; else printf 'err\t--wait needs a number of hours (like: --wait 2), not "%s"' "${_a#*=}"; return 0; fi ;;
      now|--now) _wait=0 ;;
      again|--again) _again=1 ;;
      today|t) _nd="today" ;;
      yesterday|y) _nd="yesterday" ;;
      both) _nd="both" ;;
      back|custom|c) _nd="back"; _need="back" ;;
      -*) printf 'err\t"%s" is not a word this command knows' "$_a"; return 0 ;;
      *) _picks="$_picks $_a" ;;
    esac
    if [ -n "$_nd" ]; then
      if [ -n "$_day" ] && [ "$_day" != "$_nd" ]; then printf 'err\ttwo days on one line (%s and %s) — name one: today · yesterday · both · back N' "$_day" "$_nd"; return 0; fi
      _day="$_nd"
    fi
  done
  [ "$_need" = "wait" ] && { printf 'err\t--wait needs a number of hours after it (like: --wait 2)'; return 0; }
  [ "$_day" = "back" ] && [ -z "$_back" ] && _back=7
  _picks="${_picks# }"
  _g="day"; [ "$_day" = "back" ] && _g="back"
  _bad=$(picks_check "$_g" "$_picks")
  [ -n "$_bad" ] && { printf 'err\t%s' "$_bad"; return 0; }
  printf 'ok\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$_mode" "${_where:--}" "${_wait:--}" "${_day:--}" "${_back:--}" "$_again" "$_picks"
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

# ---- reading one show -----------------------------------------------------------
# list_parse: stdin = the listing call's answer → every episode it lists, newest first, one per line:
#   <id> \t <m.d.yy> \t <days before today> \t <label>
# with the show's rhythm first: `rhythm \t <usual minute of day> \t <weekdays 1-7>` — the
# median time of day and the weekdays of the episodes posted on their own date (empty when
# fewer than three say it). The date is the one in the label; the posting day when the
# label carries none. An entry whose date cannot be read is passed over, never fatal.
# (pure; smoke-tested)
list_parse() {
  "$PY" -c '
import json,sys,re,html,datetime
raw=sys.stdin.read()
m=re.search(r"<string[^>]*>(.*)</string>", raw, re.S)
body=html.unescape(m.group(1)) if m else raw
try:
    d=json.loads(body)
    if isinstance(d,str): d=json.loads(d)
except Exception: raise SystemExit(1)
items=d.get("items",[]) if isinstance(d,dict) else d
if not isinstance(items,list): raise SystemExit(1)
def stamp(e):
    try: return int(float(e.get("createdAt") or 0))
    except Exception: return 0
items=[i for i in items if isinstance(i,dict) and i.get("id") and not i.get("isHidden")]
items.sort(key=stamp, reverse=True)
today=datetime.date.today()
mins=[]; days=set(); rows=[]
for e in items:
    eid=str(e["id"])
    if not re.match(r"^[A-Za-z0-9_-]+$", eid): continue
    label=" ".join(str(e.get("label") or e.get("seriesName") or "").split())
    m2=re.search(r"\((\d{1,2})/(\d{1,2})/(\d{2})\)", label)
    t=None; d0=None
    try:
        if stamp(e) > 0: t=datetime.datetime.fromtimestamp(stamp(e))
    except Exception: t=None
    if m2:
        mo,da,yr=(int(x) for x in m2.groups())
        try: d0=datetime.date(2000+yr,mo,da)
        except ValueError: d0=None
    if d0 is None and t: d0=t.date()
    if d0 is None: continue
    if t and t.date()==d0 and len(mins)<20:
        mins.append(t.hour*60+t.minute); days.add(t.isoweekday())
    rows.append("%s\t%d.%d.%02d\t%d\t%s" % (eid, d0.month, d0.day, d0.year%100, (today-d0).days, label))
if not rows: raise SystemExit(1)
mins.sort()
med=str(mins[len(mins)//2]) if len(mins)>=3 else ""
dd="".join(str(x) for x in sorted(days)) if len(mins)>=3 else ""
print("rhythm\t%s\t%s" % (med, dd))
print("\n".join(rows))'
}
# show_list <slug> → list_parse of the show page's own listing call.
# NMX_LISTS_DIR (the offline battery's seam): <dir>/<slug>.json is read in place of the site.
show_list() {
  if [ -n "${NMX_LISTS_DIR:-}" ]; then
    [ -s "$NMX_LISTS_DIR/$1.json" ] || return 1
    list_parse < "$NMX_LISTS_DIR/$1.json"; return $?
  fi
  _cat=$(curl -s -m 20 "https://www.newsmaxtv.com/Shows/$1" 2>/dev/null | head -c 400000 | grep -o 'category_ids=[A-Za-z0-9]*' | head -1 | sed 's/category_ids=//')
  [ -n "$_cat" ] || return 1
  curl -s -m 20 "https://www.newsmaxtv.com/api/v1/_24iService/GetPlaylist?category_ids=$_cat" 2>/dev/null | head -c 2000000 | list_parse
}
show_list_twice() {   # <slug> <file> — one more try after a breath when the site does not answer
  show_list "$1" > "$2" 2>/dev/null && [ -s "$2" ] && return 0
  [ -n "${NMX_LISTS_DIR:-}" ] && return 1
  sleep 2
  show_list "$1" > "$2" 2>/dev/null && [ -s "$2" ]
}

case "${1:-}" in
  --parse-line)   parse_line "${2:-}"; exit 0 ;;                  # smoke hooks (pure)
  --parse-picks)  picks_parse "${2:-}" "${3:-4}"; exit 0 ;;
  --custom-picks) custom_picks "${2:-}" "${3:-8}"; exit 0 ;;
  --answer-cmd)   answer_cmd "${2:-best}"; exit 0 ;;
  --parse-list)   [ -n "$PY" ] || exit 1; list_parse; exit $? ;;
  --due)          due_rule "${2:-1}" "${3:-0}" "${4:-}" "${5:-}" "${6:-3}"; exit 0 ;;
esac

# ---- the line is read whole, before anything else happens ------------------------------
_pl=$(parse_line "$*")
if [ "$(printf '%s' "$_pl" | cut -f1)" != "ok" ]; then
  printf '%s✗ %s%s\n' "$C_R" "$(printf '%s' "$_pl" | cut -f2-)" "$C_Z" >&2
  printf '  nothing was read and nothing was started · %sslipmat newsmax help%s lists every word\n' "$C_B" "$C_Z" >&2
  exit 2
fi
field() { _f=$(printf '%s' "$_pl" | cut -f"$1"); [ "$_f" = "-" ] && _f=""; printf '%s' "$_f"; }
MODE=$(field 2); WHERE=$(field 3); WAIT_H=$(field 4); DAY=$(field 5); BACK=$(field 6); AGAIN=$(field 7); PICKS=$(field 8)
[ "$MODE" = "help" ] && { usage; exit 0; }
[ -n "$WHERE" ] || { WHERE="windows"; [ "${NMX_WINDOWS:-1}" = "0" ] && WHERE="here"; }
[ -n "$WAIT_H" ] || WAIT_H="$NMX_WAIT_H"
is_hours "$WAIT_H" || WAIT_H=3
[ "$(printf '%s' "$WAIT_H" | awk '{print ($1>0)?1:0}')" = "1" ] || WAIT_H=0
TODAY_MDY=$(date +%-m.%-d.%y); TODAY_WD=$(date +%u); NOWMIN=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
[ -n "$PY" ] || die "python3 is needed to read the show pages"
[ -n "$NMX_DAILY" ] || die "no shows set — put NMX_DAILY=\"Show-Slug=best|Other-Show=quick\" in ~/.slipmat/config (the slug is the one in newsmaxtv.com/Shows/<slug>)"
[ -x "$ENGINE" ] || die "the engine is not at $ENGINE"
command -v osascript >/dev/null 2>&1 || WHERE="here"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/slipmat-newsmax.XXXXXX") || die "no scratch folder"
trap 'rm -rf "${WORK:?}" "${WORK:?}.ledgers"' EXIT
# this command's own start marks: an hour-old one is gone (empty files of its own folder only)
[ -d "$STARTED" ] && find "${STARTED:?}" -mindepth 1 -maxdepth 1 -type f -size 0 -mmin +60 -delete 2>/dev/null

window_done() {   # a menu-bar window (SLIPMAT_WINDOW=1) closes itself: <seconds> <line>
  [ "${SLIPMAT_WINDOW:-0}" = "1" ] && [ -t 0 ] && [ -f "$HERE/tools/window-close.sh" ] && /bin/bash "$HERE/tools/window-close.sh" "$1" "$2"
  return 0
}
leave() {   # x at a question, or the keyboard gone: nothing was started
  say ""; say "  nothing started"
  window_done 10 "This window closes itself in 10 s"
  exit 0
}
trim() { printf '%s' "$1" | tr -s ' \t' '  ' | sed 's/^ //; s/ $//'; }

# ---- read every show's list once, side by side -------------------------------------------
# $WORK/show.<i>   the episodes (show_list without its rhythm line)
# SLUGS · and per show, by its number: usual.<i> rowname.<i> med.<i> days.<i>
SLUGS=""; NSHOWS=0; DEAF=""
say ""
say "${C_B}NEWSMAX${C_Z}  $(date '+%A %-m.%-d.%y · %-I:%M%p' | sed 's/AM$/am/; s/PM$/pm/')"
OLDIFS=$IFS; IFS='|'; set -- $NMX_DAILY; IFS=$OLDIFS
_j=0
for _row in "$@"; do
  [ -n "$_row" ] || continue
  _slug="${_row%%=*}"
  case "$_slug" in ''|*[!A-Za-z0-9._~%-]*) say "  ${C_Y}\"$_slug\" in NMX_DAILY is not a show slug (the word after newsmaxtv.com/Shows/); passed over${C_Z}"; DEAF="$DEAF, $_slug"; continue ;; esac
  _j=$((_j+1)); printf '%s' "$_row" > "$WORK/cfg.$_j"
  ( show_list_twice "$_slug" "$WORK/raw.$_j" || : > "$WORK/raw.$_j" ) &
done
wait
_k=0
while [ "$_k" -lt "$_j" ]; do
  _k=$((_k+1)); _row=$(cat "$WORK/cfg.$_k"); _slug="${_row%%=*}"; _usual="${_row#*=}"; [ "$_usual" = "$_row" ] && _usual="best"
  if [ ! -s "$WORK/raw.$_k" ]; then
    say "  ${C_Y}$_slug — the site gave no episode list (asked twice); passed over${C_Z}"; DEAF="$DEAF, $_slug"; continue
  fi
  _i=$((NSHOWS+1)); NSHOWS=$_i; SLUGS="$SLUGS $_slug"
  _rh=$(head -1 "$WORK/raw.$_k"); sed '1d' "$WORK/raw.$_k" > "$WORK/show.$_i"
  printf '%s' "$(printf '%s' "$_rh" | cut -f2)" > "$WORK/med.$_i"; printf '%s' "$(printf '%s' "$_rh" | cut -f3)" > "$WORK/days.$_i"
  _uw=$(pick_word "$_usual")
  if [ -z "$_uw" ] || [ "$_uw" = "u" ]; then say "  ${C_Y}$_slug=$_usual in NMX_DAILY: \"$_usual\" is not an answer (b h q s or a height) — its usual reads as best${C_Z}"; _uw="best"; fi
  printf '%s' "$_uw" > "$WORK/usual.$_i"
  printf '%s' "$(show_match "$(head -1 "$WORK/show.$_i" | cut -f4)")" > "$WORK/rowname.$_i"
done
DEAF="${DEAF#, }"
[ "$NSHOWS" -gt 0 ] || die "none of the shows answered — newsmaxtv.com gave no episode list for any of them"
show_var() { cat "$WORK/$1.$2" 2>/dev/null; }   # show_var usual 2
slug_of() { printf '%s' "$SLUGS" | awk -v n="$1" '{print $n}'; }
show_label() { _sl=$(show_var rowname "$1"); [ -n "$_sl" ] || _sl=$(slug_of "$1"); printf '%s' "$_sl"; }   # the menu row, the slug when none matches
# ep_line <show n> <days back exactly | "before"> → the episode line (today = 0; "before" = the newest older than today)
ep_line() {
  if [ "$2" = "before" ]; then awk -F'\t' '$3 >= 1 { print; exit }' "$WORK/show.$1"
  else awk -F'\t' -v d="$2" '$3 == d { print; exit }' "$WORK/show.$1"; fi
}
ep_name() {   # <show n> <episode line> → "<ROW> <m.d.yy> [NMX]", the engine's name for it ("<slug> <m.d.yy>" when no menu row matches)
  _rn=$(show_var rowname "$1"); _d=$(printf '%s' "$2" | cut -f2)
  if [ -n "$_rn" ]; then printf '%s %s [NMX]' "$_rn" "$_d"; else printf '%s %s' "$(slug_of "$1")" "$_d"; fi
}
ep_state() { have_state "$(ep_name "$1" "$2")" "$(printf '%s' "$2" | cut -f1)"; }   # <show n> <episode line>
state_words() {   # <have 0|1|2|3> → the words after a name
  case "$1" in 1) printf '%s' "${C_G}in the folder${C_Z}" ;; 2) printf '%s' "${C_G}ripping now in its own window${C_Z}" ;; 3) printf '%s' "${C_G}started a moment ago${C_Z}" ;; *) : ;; esac
}
# today_state <show n> → "posted" | "late" (not posted, due inside the watch) | "off" (not posted, not due)
today_state() {
  [ -n "$(ep_line "$1" 0)" ] && { printf 'posted'; return 0; }
  if [ "$(due_rule "$TODAY_WD" "$NOWMIN" "$(show_var days "$1")" "$(show_var med "$1")" "$WAIT_H")" = "1" ]; then printf 'late'; else printf 'off'; fi
}

# ---- the overview: every show, today and the one before ---------------------------------
_i=0; _posted=0
for _slug in $SLUGS; do
  _i=$((_i+1))
  _t=$(ep_line "$_i" 0); _y=$(ep_line "$_i" before)
  _ts=$(today_state "$_i"); _med=$(show_var med "$_i")
  case "$_ts" in
    posted) _posted=$((_posted+1)); _tw="today ${C_G}$(printf '%s' "$_t" | cut -f2)${C_Z} $(state_words "$(ep_state "$_i" "$_t")")" ;;
    late)   _tw="today ${C_Y}not posted yet${C_Z}${_med:+ ${C_D}(usually about $(clock_of "$_med"))${C_Z}}" ;;
    *)      _tw="today ${C_D}not posted yet${_med:+ (usually about $(clock_of "$_med"))}${C_Z}" ;;
  esac
  if [ -n "$_y" ]; then _yl="yesterday"; [ "$(printf '%s' "$_y" | cut -f3)" = "1" ] || _yl="last"
    _yw="$_yl ${C_B}$(printf '%s' "$_y" | cut -f2)${C_Z} $(state_words "$(ep_state "$_i" "$_y")")"
  else _yw="${C_D}nothing before today${C_Z}"; fi
  say "  $(printf '%-12s' "$(show_label "$_i")")  $_tw   ·   $_yw"
  if [ "$MODE" = "list" ]; then
    say "     ${C_D}recent: $(awk -F'\t' 'NR<=10 { printf "%s%s", (NR>1?" · ":""), $2 }' "$WORK/show.$_i")${C_Z}"
  fi
done
said_cleared=0
say_cleared() {   # a reservation whose engine is gone was cleared: said once per name
  [ -s "$WORK/cleared" ] || return 0
  _sc=$(wc -l < "$WORK/cleared" | tr -d ' '); [ "$_sc" -gt "$said_cleared" ] || return 0
  sed -n "$((said_cleared+1)),\$p" "$WORK/cleared" > "$WORK/cleared.new"
  while IFS= read -r _cn; do
    say "  ${C_Y}$_cn — a rip that ended without finishing had left this name reserved; cleared, it can be ripped${C_Z}"
  done < "$WORK/cleared.new"
  said_cleared="$_sc"
}
say_cleared
if [ "$MODE" = "list" ]; then
  [ -n "$DEAF" ] && { say ""; say "  ${C_Y}no episode list from: $DEAF${C_Z}"; say ""; exit 1; }
  say ""; exit 0
fi

# ---- which day -----------------------------------------------------------------------
ask_day() {
  say ""
  say "${C_Q}Which day?${C_Z}"
  say "  ${C_B}t${C_Z}  today's        the episodes dated today — the ones not posted yet are watched for   ${C_B}[Enter]${C_Z}"
  say "  ${C_B}y${C_Z}  yesterday's    the last episode before today's (Friday's on a Monday)"
  say "  ${C_B}b${C_Z}  both           yesterday's and today's"
  say "  ${C_B}c${C_Z}  custom         today and a number of days before it, every episode listed — pick by hand"
  say "  ${C_B}x${C_Z}  leave          nothing is ripped"
  while :; do
    printf '%s%s%s ' "$C_Q" "answer" "$C_Z"
    IFS= read -r _ans || leave
    _ans=$(lc "$(trim "$_ans")")
    case " $_ans " in *" again "*) AGAIN=1; _ans=$(trim "$(printf ' %s ' "$_ans" | sed 's/ again / /g')") ;; esac
    case "$_ans" in
      ''|t|today) DAY="today"; return 0 ;;
      y|yesterday) DAY="yesterday"; return 0 ;;
      b|both) DAY="both"; return 0 ;;
      x) leave ;;
      c|custom|back)
        while :; do
          printf '%s%s%s ' "$C_Q" "How many days back?" "$C_Z [Enter = 7]"
          IFS= read -r _n || leave
          _n=$(lc "$(trim "$_n")")
          case "$_n" in '') _n=7; break ;; x) leave ;; [1-9]|[1-9][0-9]) break ;; *) say "  ${C_Y}\"$_n\" is not a number of days (1 to 99)${C_Z}" ;; esac
        done
        DAY="back"; BACK="$_n"; return 0 ;;
      *) say "  ${C_Y}\"$_ans\" is not one of t y b c x${C_Z}" ;;
    esac
  done
}
if [ -z "$DAY" ]; then
  if [ -t 0 ]; then ask_day; else DAY="today"; fi
fi

# ---- the rows: one per episode to rip ------------------------------------------------------
# $WORK/rows: <show n> \t <episode id> \t <name> \t <date> \t <state: rip|redo|have|running|late|off>
#   redo = in the folder and `again` was said: ripped once more
row_state() {   # <have 0|1|2|3> → the row's state
  case "$1" in 1) if [ "$AGAIN" = "1" ]; then printf redo; else printf have; fi ;; 2|3) printf running ;; *) printf rip ;; esac
}
build_rows() {
  : > "$WORK/rows"
  _i=0
  for _slug in $SLUGS; do
    _i=$((_i+1))
    case "$DAY" in
      today|both|yesterday)
        if [ "$DAY" != "today" ]; then
          _y=$(ep_line "$_i" before)
          if [ -n "$_y" ]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$_i" "$(printf '%s' "$_y" | cut -f1)" "$(ep_name "$_i" "$_y")" "$(printf '%s' "$_y" | cut -f2)" "$(row_state "$(ep_state "$_i" "$_y")")" >> "$WORK/rows"; fi
        fi
        if [ "$DAY" != "yesterday" ]; then
          _t=$(ep_line "$_i" 0)
          if [ -n "$_t" ]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$_i" "$(printf '%s' "$_t" | cut -f1)" "$(ep_name "$_i" "$_t")" "$(printf '%s' "$_t" | cut -f2)" "$(row_state "$(ep_state "$_i" "$_t")")" >> "$WORK/rows"
          else printf '%s\t-\t%s\t%s\t%s\n' "$_i" "$(ep_name "$_i" "$(printf -- '-\t%s' "$TODAY_MDY")")" "$TODAY_MDY" "$(today_state "$_i")" >> "$WORK/rows"; fi
        fi ;;
      back)
        awk -F'\t' -v n="$BACK" '$3 <= n' "$WORK/show.$_i" > "$WORK/span.$_i"
        while IFS= read -r _e; do
          [ -n "$_e" ] || continue
          printf '%s\t%s\t%s\t%s\t%s\n' "$_i" "$(printf '%s' "$_e" | cut -f1)" "$(ep_name "$_i" "$_e")" "$(printf '%s' "$_e" | cut -f2)" "$(row_state "$(ep_state "$_i" "$_e")")" >> "$WORK/rows"
        done < "$WORK/span.$_i" ;;
    esac
  done
  NROWS=$(wc -l < "$WORK/rows" | tr -d ' ')
  _rippable=$(awk -F'\t' '$5 == "rip" || $5 == "redo" || $5 == "late"' "$WORK/rows" | wc -l | tr -d ' ')
}
build_rows; say_cleared
row_field() { sed -n "${1}p" "$WORK/rows" | cut -f"$2"; }   # row_field 3 5 → row 3's state

# a day with nothing to rip is said so, and the question comes back (a tty) — never a silent exit
while [ "$_rippable" = "0" ]; do
  say ""
  case "$DAY" in
    today) if [ "$_posted" = "0" ]; then say "  ${C_Y}none of today's episodes are up yet, and none is due inside the watch — ${C_B}y${C_Z}${C_Y} = yesterday's${C_Z}"
           else say "  ${C_Y}today's episodes are all in the folder (or ripping now)${C_Z}"; fi ;;
    yesterday) say "  ${C_Y}yesterday's episodes are all in the folder (or ripping now)${C_Z}" ;;
    both) say "  ${C_Y}nothing of yesterday's or today's is left to rip${C_Z}" ;;
    back) say "  ${C_Y}every episode of today and the $(plural "$BACK" day days) before is in the folder (or ripping now)${C_Z}" ;;
  esac
  [ "$AGAIN" = "1" ] || [ "$(awk -F'\t' '$5 == "have"' "$WORK/rows" | wc -l | tr -d ' ')" = "0" ] \
    || { if [ -t 0 ]; then say "  ${C_Y}${C_B}again${C_Z}${C_Y} after the day rips them once more (like: ${C_B}t again${C_Z}${C_Y}) — the second copy carries its size${C_Z}"
         else say "  ${C_Y}the word ${C_B}again${C_Z}${C_Y} on the line rips one that is already in the folder (the second copy carries its size)${C_Z}"; fi; }
  if [ ! -t 0 ]; then say ""; [ -n "$DEAF" ] && exit 1; exit 0; fi
  ask_day; build_rows; say_cleared
done

# ---- the rows on screen, then how ----------------------------------------------------------
say ""
case "$DAY" in today) say "${C_B}TODAY'S${C_Z}" ;; yesterday) say "${C_B}YESTERDAY'S${C_Z}" ;; both) say "${C_B}YESTERDAY'S AND TODAY'S${C_Z}" ;; back) say "${C_B}TODAY AND THE $BACK DAY$([ "$BACK" = 1 ] || printf S) BEFORE${C_Z}" ;; esac
_k=0
while [ "$_k" -lt "$NROWS" ]; do
  _k=$((_k+1)); _n=$(row_field "$_k" 1); _nm=$(row_field "$_k" 3); _st=$(row_field "$_k" 5); _med=$(show_var med "$_n")
  case "$_st" in
    rip)     _tag="${C_D}usually $(answer_words "$(show_var usual "$_n")")${C_Z}" ;;
    redo)    _tag="${C_G}in the folder${C_Z} — ripped again, the second copy carries its size  ${C_D}usually $(answer_words "$(show_var usual "$_n")")${C_Z}" ;;
    have)    _tag="${C_G}in the folder${C_Z}" ;;
    running) _tag="${C_G}ripping now in its own window${C_Z}" ;;
    late)    _tag="${C_Y}not posted yet${_med:+ (usually about $(clock_of "$_med"))} — watched for${C_Z}" ;;
    *)       _tag="${C_D}not posted yet${_med:+ (usually about $(clock_of "$_med"))} — outside the watch, left for later${C_Z}" ;;
  esac
  say "  ${C_B}$(printf '%2s' "$_k"))${C_Z} $_nm   $_tag"
done
if [ "$DAY" = "back" ]; then
  # the site lists only each show's newest episodes: a span that reaches past them says so
  _reach=""; _i=0
  for _slug in $SLUGS; do _i=$((_i+1)); _o=$(tail -1 "$WORK/show.$_i" | cut -f3)
    case "$_o" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$_reach" ] || [ "$_o" -lt "$_reach" ]; then _reach="$_o"; fi
  done
  [ -n "$_reach" ] && [ "$BACK" -gt "$_reach" ] && say "  the site lists only each show's newest episodes: they reach $(plural "$_reach" day days) back, not $BACK"
fi

# picks_fit → NOTHING when $PICKS fits the rows on screen, else one sentence
picks_fit() {
  _g="day"; [ "$DAY" = "back" ] && _g="back"
  _bad=$(picks_check "$_g" "$PICKS"); [ -n "$_bad" ] && { printf '%s' "$_bad"; return 0; }
  [ -n "$PICKS" ] || return 0
  if [ "$DAY" = "back" ]; then
    case "$(custom_picks "$PICKS" "$NROWS" | tr -d ' -')" in '') printf 'none of those numbers is a row here (the rows are 1 to %s)' "$NROWS" ;; esac
  else
    case "$(picks_parse "$PICKS" "$NROWS")" in '!many '*) printf '%s for %s — one answer for every row, or one per row in order' "$(plural "$(printf '%s' "$PICKS" | tr ',' ' ' | wc -w | tr -d ' ')" answer answers)" "$(plural "$NROWS" row rows)" ;; esac
  fi
}
ask_how() {
  say ""
  if [ "$DAY" = "back" ]; then
    say "${C_Q}Which ones?${C_Z}  numbers, with how glued on (like: 2h 3 7q) · 2-5 = a span · all · all h"
  else
    say "${C_Q}How do you want them?${C_Z}  one answer for every row, or one per row in order (like: h b q q)"
  fi
  say "  ${C_B}b${C_Z}  best    720p CFR re-encode — the overnight pick"
  say "  ${C_B}h${C_Z}  high    native 1080p CFR re-encode at q$NMX_HIGH_Q — sharper, a longer render  (h55 = at that dial)"
  say "  ${C_B}q${C_Z}  quick   480p direct copy, no re-encode — minutes; transcribe now, re-rip later"
  say "  ${C_B}s${C_Z}  small   360p direct copy, no re-encode"
  say "  ${C_B}x${C_Z}  leave   nothing is ripped"
  if [ "$DAY" = "back" ]; then say "  a number alone = that show's usual  ·  ${C_B}[Enter]${C_Z} = every one not in the folder, each at its usual"
  else say "  or a height (720 480 360)  ·  ${C_B}[Enter]${C_Z} = each show's usual (the list above)"; fi
  while :; do
    printf '%s%s%s ' "$C_Q" "answer" "$C_Z"
    IFS= read -r PICKS || leave
    PICKS=$(trim "$PICKS")
    case "$(lc "$PICKS")" in x) leave ;; esac
    _why=$(picks_fit); [ -z "$_why" ] && return 0
    say "  ${C_Y}$_why${C_Z}"
  done
}
# picks from the line that do not fit the rows: asked again (a tty), refused (nobody there)
_why=$(picks_fit)
if [ -n "$_why" ]; then
  if [ -t 0 ]; then say ""; say "  ${C_Y}$_why${C_Z}"; PICKS=""; ask_how
  else printf '\n%s✗ %s%s\n  nothing was started\n\n' "$C_R" "$_why" "$C_Z" >&2; exit 2; fi
elif [ -z "$PICKS" ]; then
  if [ -t 0 ]; then ask_how
  elif [ "$DAY" = "back" ]; then
    # nobody is there to pick: a span of days is never ripped whole on a guess
    say ""; say "  back $BACK lists the episodes; picks start them — ${C_B}slipmat newsmax back $BACK all${C_Z} rips every one not in the folder, ${C_B}back $BACK 2h 3${C_Z} rows 2 and 3"; say ""
    [ -n "$DEAF" ] && exit 1; exit 0
  fi
fi
# PICKSET: one answer per row; `u` = the show's usual; `-` = not chosen (custom only)
if [ "$DAY" = "back" ]; then
  if [ -z "$PICKS" ]; then PICKSET=$(custom_picks "all" "$NROWS"); else PICKSET=$(custom_picks "$PICKS" "$NROWS"); fi
else PICKSET=$(picks_parse "$PICKS" "$NROWS"); fi
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
_ran=0; _skipped=0; _unpicked=0; _nowin=""; _unfinished=""; _waiting=""
# rip_one <k> <show n> <episode id> <name> <answer> <clock or ""> — a window, or here.
# The folder is read once more first: a rip another window began since the rows were built is left alone.
rip_one() {
  case "$(have_state "$4" "$3")" in
    1) if [ "$AGAIN" != "1" ]; then _skipped=$((_skipped+1)); say "  ${C_D}$1) $4 — landed in the folder meanwhile, skipped${C_Z}"; return 0; fi ;;
    2) _skipped=$((_skipped+1)); say "  ${C_D}$1) $4 — ripping now in its own window, left alone${C_Z}"; return 0 ;;
    3) _skipped=$((_skipped+1)); say "  ${C_D}$1) $4 — started a moment ago by another run of this command, left alone${C_Z}"; return 0 ;;
  esac
  if ! start_mark "$3"; then _skipped=$((_skipped+1)); say "  ${C_D}$1) $4 — started a moment ago by another run of this command, left alone${C_Z}"; return 0; fi
  _url="https://www.newsmaxtv.com/Shows/$(slug_of "$2")/vid/$3"
  _env=""; _args=""
  for _w in $(answer_cmd "$5"); do case "$_w" in SLIPMAT_*=*) _env="$_env $_w" ;; *) _args="$_args $_w" ;; esac; done
  _env="${_env# }"; _args="${_args# }"
  if [ "$WHERE" = "windows" ]; then
    _cmd="$_env $(printf '%q' "$ENGINE") $(printf '%q' "$_url") $_args"
    if open_window "${_cmd# }"; then
      _ran=$((_ran+1)); say "  ${C_B}$1)${C_Z} $4 — $(answer_words "$5") · its window is open${6:+ · $6}"
    else
      start_unmark "$3"; _nowin="$_nowin · $4"
      say "  ${C_R}$1) $4 — Terminal would not open a window for it; not started${C_Z}"
    fi
  else
    say ""
    say "${C_B}── $1 of $NROWS · $4 · $(answer_words "$5")${6:+ · $6} ──${C_Z}"
    if env $_env "$ENGINE" "$_url" $_args; then _ran=$((_ran+1)); else _unfinished="$_unfinished · $4"; fi
  fi
}
_k=0
say ""
while [ "$_k" -lt "$NROWS" ]; do
  _k=$((_k+1)); _n=$(row_field "$_k" 1); _eid=$(row_field "$_k" 2); _nm=$(row_field "$_k" 3); _st=$(row_field "$_k" 5)
  _a=$(row_pick "$_k")
  case "$_st" in
    late)    if [ "$_a" = "-" ]; then _unpicked=$((_unpicked+1)); continue; fi
             _waiting="$_waiting $_k"; say "  ${C_Y}$_k) $(show_label "$_n") — not posted yet; watching for it${C_Z}" ;;
    off)     [ "$_a" = "-" ] && { _unpicked=$((_unpicked+1)); continue; }
             say "  ${C_D}$_k) $(show_label "$_n") — not posted yet, usually about $(clock_of "$(show_var med "$_n")"); left for later${C_Z}" ;;
    running) [ "$_a" = "-" ] && { _unpicked=$((_unpicked+1)); continue; }
             _skipped=$((_skipped+1)); say "  ${C_D}$_k) $_nm — ripping now in its own window, left alone${C_Z}" ;;
    have)    [ "$_a" = "-" ] && { _unpicked=$((_unpicked+1)); continue; }
             _skipped=$((_skipped+1)); say "  ${C_D}$_k) $_nm — already in the folder, skipped${C_Z}" ;;
    *)       if [ "$_a" = "-" ]; then _unpicked=$((_unpicked+1)); continue; fi
             rip_one "$_k" "$_n" "$_eid" "$_nm" "$_a" "" ;;
  esac
done
_waiting="${_waiting# }"
# ---- the wait: today's shows not posted yet are read again every few minutes ---------------
# A show counts as posted the moment its list carries an episode dated the day the watch
# began (a watch that runs past midnight still looks for that day's episode); it is ripped
# then with its own answer (its window opens, or it runs here). The watch ends when every
# show is in, or after NMX_WAIT_H hours (3), and says which never came. x ends the watch
# early (asked once); the rips already running are not touched. No other key reads the
# site sooner: the site is read on the clock only.
_never=""; _never_n=0; _late_n=0; _stopped=0; _asked=0
if [ -n "$_waiting" ]; then
  _late_n=$(printf '%s' "$_waiting" | wc -w | tr -d ' ')
  _end=$(( $(date +%s) + $(printf '%s' "$WAIT_H" | awk '{printf "%d", $1*3600}') ))
  _every="${NMX_WAIT_EVERY:-600}"; case "$_every" in ''|0|*[!0-9]*) _every=600 ;; esac   # whole seconds, never a tight loop on the site
  _keys=0; [ -t 0 ] && _keys=1
  say ""
  say "${C_B}WATCHING${C_Z} for $(plural "$_late_n" show shows) not posted yet — reading the site every $([ "$_every" -ge 60 ] && printf '%s min' "$((_every/60))" || printf '%s s' "$_every") until $(date -r "$_end" +%-I:%M%p | tr A-Z a-z), ripping each when it drops$([ "$_keys" = 1 ] && printf ' · %sx%s ends the watch' "$C_B" "$C_Z")"
  _next=$(( $(date +%s) + _every ))
  while [ -n "$_waiting" ]; do
    _nowS=$(date +%s); [ "$_nowS" -lt "$_end" ] || break
    _left=$(( _next - _nowS )); [ "$_left" -gt $(( _end - _nowS )) ] && _left=$(( _end - _nowS ))
    if [ "$_left" -gt 0 ]; then
      if [ "$_keys" = "1" ]; then
        _key=""
        if IFS= read -r -s -t "$_left" -n 1 _key 2>/dev/null; then
          case "$_key" in
            x|X) if [ "$_asked" = "0" ]; then _asked=1; say "  ${C_Q}end the watch?${C_Z}  ${C_B}x${C_Z} again ends it · any other key keeps watching"
                 else _stopped=1; say "  watch ended — $(plural "$(printf '%s' "$_waiting" | wc -w | tr -d ' ')" show shows) left unwatched"
                      IFS= read -r -s -t 1 -n 100 _junk 2>/dev/null   # keys banged after the stop land nowhere
                      break; fi ;;
            *) [ "$_asked" = "1" ] && say "  still watching"; _asked=0 ;;
          esac
        else
          # the wait ran out — or the keyboard is gone (the read came back at once): then wait on the clock alone
          [ "$(date +%s)" -lt $(( _nowS + _left )) ] && _keys=0
        fi
      else sleep "$_left"; fi
      continue
    fi
    _asked=0; _still=""
    for _k in $_waiting; do
      _n=$(row_field "$_k" 1); _a=$(row_pick "$_k")
      show_list "$(slug_of "$_n")" 2>/dev/null | sed '1d' > "$WORK/again.$_n"
      _t=$(awk -F'\t' -v d="$TODAY_MDY" '$2 == d { print; exit }' "$WORK/again.$_n")
      [ -n "$_t" ] || { _still="$_still $_k"; continue; }
      _nm=$(ep_name "$_n" "$_t"); _eid=$(printf '%s' "$_t" | cut -f1)
      _clock=$(date +%-I:%M%p | tr A-Z a-z)
      say "  ${C_G}$_k) $_nm — posted · $_clock${C_Z}"
      rip_one "$_k" "$_n" "$_eid" "$_nm" "$_a" "$_clock"
    done
    _waiting="${_still# }"
    _next=$(( $(date +%s) + _every ))
  done
  for _k in $_waiting; do _never="$_never $(show_label "$(row_field "$_k" 1)")"; _never_n=$((_never_n+1)); done
fi
say_cleared
say ""
_w=""; [ "$((_late_n - _never_n))" -gt 0 ] && _w=" · $((_late_n - _never_n)) picked up while watching"
if [ "$_stopped" = "1" ] && [ -n "$_never" ]; then _w="$_w · watch ended early, still not posted:${_never}"
elif [ -n "$_never" ]; then _w="$_w · never posted in the ${WAIT_H} h:${_never}"; fi
[ "$_unpicked" -gt 0 ] && _w="$_w · $_unpicked not picked"
[ -n "$_nowin" ] && _w="$_w · no window opened for: ${_nowin# · } (--here rips in this window)"
[ -n "$_unfinished" ] && _w="$_w · did not finish: ${_unfinished# · }"
[ -n "$DEAF" ] && _w="$_w · no episode list from: $DEAF"
if [ "$WHERE" = "windows" ]; then
  _tail=""; [ "$_ran" -gt 0 ] && _tail=" · each window closes itself when its rip is done (x stops it, ↓ steps a slow download down)"
  say "${C_B}NEWSMAX${C_Z} — $(plural "$_ran" window windows) opened · $_skipped already there$_w$_tail"
else say "${C_B}NEWSMAX${C_Z} — $_ran ripped · $_skipped already there$_w"; fi
# a menu-bar window (SLIPMAT_WINDOW=1) closes itself once the shows are off in their own windows
[ "$WHERE" = "windows" ] && window_done 45 "This window closes itself in 45 s — the shows run in their own windows"
[ -n "$_nowin$_unfinished$DEAF" ] && exit 1
exit 0
