#!/bin/bash
# window-close.sh — a finished run's Terminal window closes itself (10.29.26).
#   bash window-close.sh <seconds> [<line>]
# Called as the LAST act of a run that has already printed its receipt. It prints
# the line, waits <seconds> for a key (any key keeps the window open), then hands
# the close to a detached helper that waits for the caller to exit and closes
# THIS tty's Terminal tab — only that tab, found by its tty, never a neighbor.
# Only the launcher's own windows ask for this (the launcher sets SLIPMAT_WINDOW=1);
# a run typed into your own tab is never closed. Not a tty, or not Terminal.app →
# nothing happens.
set -u
SECS="${1:-300}"; case "$SECS" in ''|*[!0-9]*) SECS=300 ;; esac
[ "$SECS" -gt 0 ] || exit 0
[ -c /dev/tty ] || exit 0
[ "${TERM_PROGRAM:-}" = "Apple_Terminal" ] || exit 0
TTY=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' '); case "$TTY" in ttys*) TTY="/dev/$TTY" ;; *) exit 0 ;; esac
CALLER=$PPID
if [ "$SECS" -ge 120 ]; then _in="$(( SECS / 60 )) min"; else _in="$SECS s"; fi
if [ -t 1 ]; then R=$'\033[0m'; KC=$'\033[1;7;35m'; D=$'\033[2m'; else R=""; KC=""; D=""; fi
chip() { if [ -n "$KC" ]; then printf '%s %s %s' "$KC" "$1" "$R"; else printf '[%s]' "$1"; fi; }
LINE="${2:-This window closes itself in $_in}"
# the three lines are the user's own copy (10.29.26): x or Enter closes now,
# any other key keeps the window. The read owns the tty for the wait; a key
# typed earlier was eaten by the run's own reader, so this is a fresh answer.
printf '\n  %s\n  %s close now\n  %s keep open\n' "$LINE" "$(chip "x or ENTER")" "$(chip "any other key")"
if read -r -s -n 1 -t "$SECS" _k < /dev/tty 2>/dev/null; then
  case "$_k" in
    x|X|'') printf '  %sclosing%s\n' "$D" "$R" ;;
    *) printf '  %sok — the window stays%s\n' "$D" "$R"; exit 0 ;;
  esac
fi
# no key: a new session (setsid — no controlling tty, so Terminal sees only the
# login shell when it closes) waits for the caller to be gone, then closes the tab.
/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- /bin/bash -c '
  n=0; while kill -0 "$1" 2>/dev/null && [ $n -lt 20 ]; do sleep 0.5; n=$((n+1)); done
  sleep 0.5
  /usr/bin/osascript - "$2" <<'"'"'AS'"'"' >/dev/null 2>&1
on run argv
  set want to item 1 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if tty of t is want then
            if (count of tabs of w) is 1 then
              close w
            else
              close t
            end if
            return
          end if
        end try
      end repeat
    end repeat
  end tell
end run
AS
' _ "$CALLER" "$TTY" </dev/null >/dev/null 2>&1 &
exit 0
