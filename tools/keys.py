#!/usr/bin/env python3
# slipmat key reader — the keys a user may press while a download or a live
# capture is running, each one shown on the screen, each one meaning ONE thing.
#
#   live capture (in-process, via live-rewind.py):  x  = stop & seal, asked once:
#       first x  → the REC line becomes a question ("stop the capture? x again =
#                  stop · any other key = keep recording"), 5 s to answer
#       second x → the exact first-Ctrl-C path (seal, key disarmed until done)
#       Ctrl-C   → the stop at once (a reflex is honored; the seal is never at risk)
#   download ladder (a background job the engine starts):  ↓  = step down a rung:
#       ↓        → interrupts yt-dlp the way Ctrl-C does, but leaves a flag file
#                  (key.down) so the engine reads it as "take the next rung down";
#                  at the bottom rung (key.next empty) it says so and does nothing
#       Ctrl-C   → cancel, nothing kept (the engine's by_hand sees NO flag)
#
# The terminal is put in cbreak mode with echo off (keys arrive one at a time and
# never print) and is restored on every exit path. Non-tty runs never start this.
import os, select, signal, sys, termios

ESC = b'\x1b'
DOWN = (b'\x1b[B', b'\x1bOB')


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
    if fd >= 0 and saved is not None:
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
    mode while the capture runs; live-rewind.py restores it at exit."""
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
            k = read_key(fd, 5.0 if armed else 1.0)
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


# ---- download ladder: a standalone background job -----------------------------
def main(argv):
    # keys.py ladder <engine pid> <workdir>
    if len(argv) < 4 or argv[1] != 'ladder':
        sys.exit(2)
    ppid = int(argv[2]); work = argv[3]
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
    try:
        while True:
            try:
                os.kill(ppid, 0)       # the engine is gone → so are we (never orphan a raw tty)
            except OSError:
                break
            k = read_key(fd, 1.0)
            if k in DOWN:
                try:
                    nxt = open(os.path.join(work, 'key.next')).read().strip()
                except OSError:
                    nxt = ''
                if not nxt:
                    say(fd, '  nothing lower than this rung — it keeps going (Ctrl-C = cancel)\n')
                    continue
                try:
                    open(os.path.join(work, 'key.down'), 'w').close()
                except OSError:
                    pass
                # the yt-dlp child of the engine gets the same signal a Ctrl-C sends it;
                # the flag above is what tells the engine this was the ↓ key
                import subprocess
                try:
                    kids = subprocess.run(['pgrep', '-P', str(ppid), '-f', 'yt[-_]dlp'], capture_output=True, text=True).stdout.split()
                except Exception:
                    kids = []
                for pid in kids:
                    try:
                        os.kill(int(pid), signal.SIGINT)
                    except OSError:
                        pass
                if not kids:
                    try:
                        os.unlink(os.path.join(work, 'key.down'))
                    except OSError:
                        pass
    finally:
        restore(fd, saved)


if __name__ == '__main__':
    main(sys.argv)
