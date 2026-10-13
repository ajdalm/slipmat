#!/usr/bin/env python3
# slipmat key reader — the keys a user may press while slipmat works, each one
# shown on the screen before it can be pressed, each one meaning ONE thing:
#
#   x   = stop. Asked once: the first x prints a question ("stop the …? x again
#         = stop · any other key = keep going"), a second x within 5 s stops.
#         Any other key, or 5 s of nothing, keeps going (said). After the stop
#         every further key is swallowed until the engine has finished its
#         receipt — a third, fourth, fifth x can never land anywhere.
#   ↓   = step down one rung (downloads with a rung below, shown with the rung).
#   Ctrl-C is not a slipmat key: the terminal's own emergency exit, out at once.
#
#   live capture (in-process thread, via live-rewind.py): the second x takes the
#       exact first-Ctrl-C path (seal one playable mp4; keys off until sealed).
#   download / re-encode (`keys.py watch <engine pid> <workdir>`, a background
#       job the engine starts): the second x leaves key.x in the scratch and
#       interrupts the engine's yt-dlp / ffmpeg child the way Ctrl-C would — the
#       engine reads the flag to say "canceled (x)". ↓ leaves key.down the same
#       way; key.next (written by the engine before every attempt) is the rung ↓
#       would take: missing = no ladder on this screen (↓ does nothing), empty =
#       the floor (said, nothing interrupted).
#
# The terminal is put in cbreak mode with echo off (keys arrive one at a time and
# never print) and is restored — input flushed — on every exit path. Non-tty runs
# never start this.
import os, select, signal, sys, termios, time

ESC = b'\x1b'
DOWN = (b'\x1b[B', b'\x1bOB')
ASK_WINDOW = 5.0


def _open_tty():
    try:
        return os.open('/dev/tty', os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return -1


def cbreak(fd):
    """cbreak + no echo; returns the attrs to restore (None if the tty is unusable)."""
    try:
        saved = termios.tcgetattr(fd)
        a = termios.tcgetattr(fd)
        a[3] &= ~(termios.ICANON | termios.ECHO)
        a[6][termios.VMIN] = 1
        a[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, a)
        return saved
    except Exception:
        return None


def restore(fd, saved):
    """drop whatever was typed and never answered, then put the mode back."""
    if fd >= 0 and saved is not None:
        try:
            termios.tcflush(fd, termios.TCIFLUSH)
        except Exception:
            pass
        try:
            termios.tcsetattr(fd, termios.TCSANOW, saved)
        except Exception:
            pass


def read_key(fd, timeout):
    """one keypress (an arrow arrives as its whole escape sequence); '' on timeout."""
    r, _, _ = select.select([fd], [], [], timeout)
    if not r:
        return b''
    try:
        k = os.read(fd, 1)
    except OSError:
        return b''
    if k == ESC:   # the rest of an escape sequence follows within a few ms; a lone ESC does not
        r, _, _ = select.select([fd], [], [], 0.05)
        while r:
            try:
                k += os.read(fd, 8)
            except OSError:
                break
            r, _, _ = select.select([fd], [], [], 0.01)
    return k


def say(fd, line):
    try:
        os.write(fd, b'\r\033[K' + line.encode('utf-8', 'replace'))
    except OSError:
        pass


# ---- live: a thread inside live-rewind.py ------------------------------------
def live_thread(stop_cb, ask_flag, ask_text, stop_text):
    """runs until stop_cb() has been called (by us or by a Ctrl-C). Owns the tty
    mode while the capture runs; live-rewind.py restores it at exit. After the
    second x the thread ends at once — nothing reads keys again until the engine
    re-arms the terminal after its receipt (and it flushes what was typed)."""
    fd = _open_tty()
    if fd < 0:
        return None
    saved = cbreak(fd)
    if saved is None:
        return None
    import threading

    def loop():
        armed = False
        while not stop_cb.done:
            k = read_key(fd, ASK_WINDOW if armed else 1.0)
            if stop_cb.done:
                break
            if armed:
                armed = False
                try:
                    os.unlink(ask_flag)
                except OSError:
                    pass
                if k in (b'x', b'X'):
                    say(fd, stop_text)
                    stop_cb()          # the first-Ctrl-C path, exactly
                    break
                say(fd, '')            # the REC line redraws on its next tick
                continue
            if k in (b'x', b'X'):
                armed = True
                try:
                    open(ask_flag, 'w').close()
                except OSError:
                    pass
                say(fd, ask_text)
    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return saved


# ---- download / re-encode: a standalone background job -------------------------
def _engine_children(ppid):
    """pids of the engine's yt-dlp (child or grandchild — a wrapper script may sit
    between) and ffmpeg (direct child: the encode) processes, the thing a Ctrl-C
    would hit. Matched on the command line, since a pip yt-dlp runs as python."""
    import subprocess

    def kids_of(pid):
        try:
            return subprocess.run(['pgrep', '-P', str(pid)], capture_output=True, text=True).stdout.split()
        except Exception:
            return []

    def rows_for(pids):
        if not pids:
            return []
        try:
            out = subprocess.run(['ps', '-o', 'pid=,command=', '-p', ','.join(pids)], capture_output=True, text=True).stdout
        except Exception:
            return []
        rows = []
        for row in out.splitlines():
            parts = row.split()
            if len(parts) >= 2:
                rows.append((parts[0], [os.path.basename(x) for x in parts[1:3]]))
        return rows

    hit = []
    direct = kids_of(ppid)
    _dbg = os.environ.get('SLIPMAT_KEYS_DEBUG', '')
    if _dbg:
        try:
            with open(_dbg, 'a') as fh:
                fh.write('ppid=%s direct=%s rows=%s\n' % (ppid, direct, rows_for(direct)))
        except OSError:
            pass
    for pid, names in rows_for(direct):
        if any(n == 'ffmpeg' or n.startswith('yt-dlp') for n in names):
            hit.append(int(pid))
    if not hit:   # yt-dlp behind a wrapper: one level down, yt-dlp only
        grand = [g for c in direct for g in kids_of(c)]
        for pid, names in rows_for(grand):
            if any(n.startswith('yt-dlp') for n in names):
                hit.append(int(pid))
    return hit


def _interrupt(ppid, flag, tries=10):
    """leave the flag, then send the child the signal a Ctrl-C would. A child that
    is not there yet (between two attempts) is waited for, briefly."""
    try:
        open(flag, 'w').close()
    except OSError:
        pass
    for _ in range(tries):
        kids = _engine_children(ppid)
        if kids:
            for pid in kids:
                try:
                    os.kill(pid, signal.SIGINT)
                except OSError:
                    pass
            return True
        time.sleep(0.2)
    try:
        os.unlink(flag)
    except OSError:
        pass
    return False


def main(argv):
    # keys.py watch <engine pid> <workdir>   (`ladder` = the same, older name)
    if len(argv) < 4 or argv[1] not in ('watch', 'ladder'):
        sys.exit(2)
    ppid = int(argv[2]); work = argv[3]
    ask_text = os.environ.get('SLIPMAT_KEYS_ASK', '  stop? x again = stop · any other key = keep going')
    kept_text = os.environ.get('SLIPMAT_KEYS_KEPT', '  keeps going')
    floor_text = os.environ.get('SLIPMAT_KEYS_FLOOR', '  nothing lower than this rung — it keeps going')
    fd = _open_tty()
    if fd < 0:
        sys.exit(0)
    saved = cbreak(fd)
    if saved is None:
        sys.exit(0)

    def bye(*_):
        restore(fd, saved)
        os._exit(0)
    for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(s, bye)
    armed_until = 0.0     # > 0 while the x question is up
    spent = False         # the stop landed: swallow everything until the engine is gone
    try:
        while True:
            try:
                os.kill(ppid, 0)       # the engine is gone → so are we (never orphan a raw tty)
            except OSError:
                break
            if armed_until:
                left = armed_until - time.monotonic()
                if left <= 0:
                    armed_until = 0.0
                    say(fd, kept_text + '\n')
                    continue
                k = read_key(fd, min(1.0, left))
            else:
                k = read_key(fd, 1.0)
            if not k or spent:
                continue
            if armed_until:
                armed_until = 0.0
                if k in (b'x', b'X'):
                    spent = True
                    _interrupt(ppid, os.path.join(work, 'key.x'))
                else:
                    say(fd, kept_text + '\n')
                continue
            if k in (b'x', b'X'):
                armed_until = time.monotonic() + ASK_WINDOW
                say(fd, ask_text + '\n')
                continue
            if k in DOWN:
                try:
                    nxt = open(os.path.join(work, 'key.next')).read().strip()
                except OSError:
                    continue           # no ladder on this screen: the key was never offered
                if not nxt:
                    say(fd, floor_text + '\n')
                    continue
                _interrupt(ppid, os.path.join(work, 'key.down'))
    finally:
        restore(fd, saved)


if __name__ == '__main__':
    main(sys.argv)
