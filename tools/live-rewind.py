#!/usr/bin/env python3
# live-rewind.py — yt-dlp in-process, for livestream captures. Two jobs:
#
# 1. A rewind window (SLIPMAT_LIVE_BACK=<seconds>). yt-dlp's --live-from-start
#    already contains "start N seconds behind the live head": its YouTube fragment
#    generator refuses to reach back past MAX_DURATION (120 hours, the most YouTube
#    keeps) and, when the stream is older than that, begins at head − MAX_DURATION.
#    That constant is the whole rewind window; this swaps it for the asked seconds.
#    A stream younger than the window starts from its first fragment. Unset / 0 =
#    plain yt-dlp. The constant is found by value, never by position; if a yt-dlp
#    update moves or renames it, this exits 86 with one line and the engine falls
#    back honestly to recording from now.
#
# 2. The FIRST Ctrl-C is the stop; later presses are nothing (10.5.26 eve). yt-dlp
#    seals a live capture on its first KeyboardInterrupt (two fragment streams
#    finish, merge into one mp4; or ffmpeg writes the mp4 trailer). A second press
#    while that runs escaped as a real abort and left video-only + audio .part
#    files — seen in the field. So on the first SIGINT this: touches the stop flag
#    (SLIPMAT_LIVE_STOP, the engine's REC line reads it and says "stopping"),
#    DISARMS the terminal's interrupt key (termios VINTR) so the terminal never
#    generates another SIGINT for this process group — including yt-dlp's ffmpeg
#    child, which would hard-exit on its second one — and then raises
#    KeyboardInterrupt exactly as before. The ENGINE re-arms the key once its
#    receipt is written (standalone use re-arms at exit). Closing the window
#    (SIGHUP) still abandons.
import atexit, os, signal, sys

_fd = -1
try:
    _fd = os.open('/dev/tty', os.O_RDWR | os.O_NOCTTY)
except OSError:
    pass
_saved = None
_presses = 0


def _rearm():
    if _fd >= 0 and _saved is not None:
        try:
            import termios
            termios.tcsetattr(_fd, termios.TCSANOW, _saved)
        except Exception:
            pass


def _disarm():
    global _saved
    if _fd < 0:
        return
    try:
        import termios
        attrs = termios.tcgetattr(_fd)
        _saved = [a if not isinstance(a, list) else list(a) for a in attrs]
        try:
            off = os.fpathconf(_fd, 'PC_VDISABLE')
        except (OSError, ValueError):
            off = 0xff   # macOS _POSIX_VDISABLE
        cc = list(attrs[6])
        cc[termios.VINTR] = bytes([off]) if isinstance(cc[termios.VINTR], bytes) else off
        attrs[6] = cc
        attrs[3] &= ~termios.ECHO   # a disarmed ^C would otherwise echo as "^C" on the stopping line
        termios.tcsetattr(_fd, termios.TCSANOW, attrs)
        # Under the engine (SLIPMAT_LIVE_STOP set) the ENGINE re-arms the key, after
        # its own sealing and receipt — re-arming here, at yt-dlp's exit, left the
        # receipt exposed to a third press (seen in the proof). Standalone: re-arm at exit.
        if not os.environ.get('SLIPMAT_LIVE_STOP', ''):
            atexit.register(_rearm)
    except Exception:
        _saved = None


def _on_sigint(signum, frame):
    global _presses
    _presses += 1
    if _presses == 1:
        _disarm()
        flag = os.environ.get('SLIPMAT_LIVE_STOP', '')
        if flag:
            try:
                open(flag, 'w').close()
            except OSError:
                pass
        elif _fd >= 0:
            try:
                os.write(_fd, b'\r\033[K  stopping - sealing the capture; Ctrl-C is off until it is done\n')
            except OSError:
                pass
        raise KeyboardInterrupt
    # a later press: the key is disarmed, but a signal sent by hand (kill -INT)
    # still lands here — ignored on purpose; the seal must finish.


signal.signal(signal.SIGINT, _on_sigint)

back = int(os.environ.get('SLIPMAT_LIVE_BACK', '0') or 0)
if back > 0:
    try:
        from yt_dlp.extractor.youtube import YoutubeIE
        fn = YoutubeIE._live_adaptive_fragments
        code = fn.__code__
        consts = list(code.co_consts)
        hit = [i for i, c in enumerate(consts) if isinstance(c, tuple) and len(c) == 2 and c[1] == 432000]
        if len(hit) != 1:
            raise RuntimeError('rewind constant not found in this yt-dlp')
        consts[hit[0]] = (consts[hit[0]][0], back)
        fn.__code__ = code.replace(co_consts=tuple(consts))
    except Exception as e:  # anything: the engine reads exit 86 as "no rewind here"
        sys.stderr.write(f'live-rewind: {e}\n')
        sys.exit(86)
import yt_dlp
try:
    rc = yt_dlp.main()
except SystemExit as e:
    rc = e.code
finally:
    if not os.environ.get('SLIPMAT_LIVE_STOP', ''):
        _rearm()
sys.exit(rc)
