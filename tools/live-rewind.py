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
#
# 3. A stop KEY, shown on the REC line (10.5.26 night): x, asked once. tools/keys.py
#    reads the terminal in a thread; the first x turns the REC line into a question
#    (SLIPMAT_LIVE_ASK_FLAG + SLIPMAT_LIVE_ASK_TEXT), a second x within 5 s takes
#    the exact first-Ctrl-C path above. Any other key keeps recording. Ctrl-C stays
#    the immediate stop. The stop flag's CONTENT names which key stopped it.
#
# 4. How far behind live each stream is (11.2.26, SLIPMAT_LIVE_LAG=<file>). A rewind
#    downloads its video and its audio as two threads, one fragment at a time; the
#    audio (tiny fragments) reaches the live head long before the video, so a stop
#    while the video is still behind ends the picture early with the sound running
#    on. yt-dlp's fragment generator yields each fragment's sequence number beside
#    the head's; this wraps it and writes "video <s>" / "audio <s>" (seconds behind
#    live) to the file on every fragment. The engine's REC line reads it. Anything
#    odd here is logged once and the capture runs without the file.
import atexit, os, signal, sys

_fd = -1
try:
    _fd = os.open('/dev/tty', os.O_RDWR | os.O_NOCTTY)
except OSError:
    pass
_saved = None
_presses = 0
_orig = None          # tty attrs from BEFORE the key thread's cbreak (restored at exit)


class _Stop:          # the key thread's way in: the first-Ctrl-C path, by name
    done = False
    how = 'Ctrl-C'
    def __call__(self):
        import threading
        self.how = 'x'
        try:
            signal.pthread_kill(threading.main_thread().ident, signal.SIGINT)
        except Exception:
            os.kill(os.getpid(), signal.SIGINT)
_stop = _Stop()


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
        _stop.done = True
        _disarm()
        flag = os.environ.get('SLIPMAT_LIVE_STOP', '')
        if flag:
            try:
                with open(flag, 'w') as fh:
                    fh.write(_stop.how)     # the engine's log says which key stopped it
            except OSError:
                pass
            txt = os.environ.get('SLIPMAT_LIVE_STOP_TEXT', '')
            if txt and _fd >= 0 and _stop.how != 'x':   # said ONCE: the key thread already said it on x x; a Ctrl-C says it here (10.29.26)
                try:
                    os.write(_fd, b'\r\033[K' + txt.encode('utf-8', 'replace'))
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
_lag_path = os.environ.get('SLIPMAT_LIVE_LAG', '')
if _lag_path:
    try:
        import threading, time
        from urllib.parse import parse_qs, urlparse
        from yt_dlp.extractor.youtube import YoutubeIE as _LagIE
        _lag_orig = _LagIE._live_adaptive_fragments
        # YouTube's audio-only itags (DASH 139/140/141/249/250/251, HLS 233/234,
        # the rest the rarer ones); anything else is the video
        _LAG_AUDIO = {139, 140, 141, 171, 233, 234, 249, 250, 251, 256, 258, 325, 327, 328, 338, 380}
        _lag_state, _lag_lock = {}, threading.Lock()

        def _lag_write(kind, behind):
            with _lag_lock:
                _lag_state[kind] = max(0, int(behind))
                tmp = _lag_path + '.tmp'
                try:
                    with open(tmp, 'w') as fh:
                        fh.write(''.join(f'{k} {v}\n' for k, v in sorted(_lag_state.items())))
                    os.replace(tmp, _lag_path)
                except OSError:
                    pass

        def _lag_fragments(self, *a, **kw):
            itag = a[1] if len(a) > 1 else kw.get('itag')
            dur = a[6] if len(a) > 6 else kw.get('fragment_duration')
            try:
                kind = 'audio' if int(itag) in _LAG_AUDIO else 'video'
            except (TypeError, ValueError):
                kind = 'video'
            head, head_t = None, 0.0
            for frag in _lag_orig(self, *a, **kw):
                try:
                    fc = frag.get('fragment_count')          # the head's sequence + 1, as of head_t
                    idx = int(parse_qs(urlparse(frag['url']).query)['sq'][0])
                    if fc != head:
                        head, head_t = fc, time.time()
                    if fc is not None and dur:
                        _lag_write(kind, (fc - 1 - idx) * float(dur) + (time.time() - head_t))
                except Exception:
                    pass
                yield frag
        _LagIE._live_adaptive_fragments = _lag_fragments
    except Exception as e:
        sys.stderr.write(f'live-rewind: no lag file ({e}); the capture runs without it\n')
# the stop key (a thread reading the terminal; the engine passes the texts it shows)
_ask_flag = os.environ.get('SLIPMAT_LIVE_ASK_FLAG', '')
if _ask_flag and _fd >= 0:
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import keys as _keys
        _orig = _keys.live_thread(_stop, _ask_flag,
                                  os.environ.get('SLIPMAT_LIVE_ASK_TEXT', ''),
                                  os.environ.get('SLIPMAT_LIVE_STOP_TEXT', ''))
    except Exception as e:
        sys.stderr.write(f'live-rewind: no stop key ({e}); Ctrl-C still stops\n')
        _orig = None


def _restore_mode():
    # put the terminal back the way it was before the key thread (cooked, echo) —
    # but if a stop landed, keep the interrupt key OFF and echo OFF: the engine
    # re-arms both after its receipt (a third press once killed the receipt)
    if _fd < 0:
        return
    try:
        import termios
        if _orig is not None:
            a = [x if not isinstance(x, list) else list(x) for x in _orig]
            if _stop.done and os.environ.get('SLIPMAT_LIVE_STOP', ''):
                try:
                    off = os.fpathconf(_fd, 'PC_VDISABLE')
                except (OSError, ValueError):
                    off = 0xff
                a[6][termios.VINTR] = bytes([off]) if isinstance(a[6][termios.VINTR], bytes) else off
                a[3] &= ~termios.ECHO
            termios.tcsetattr(_fd, termios.TCSANOW, a)
        elif not os.environ.get('SLIPMAT_LIVE_STOP', ''):
            _rearm()
    except Exception:
        pass


try:
    rc = yt_dlp.main()
except SystemExit as e:
    rc = e.code
finally:
    _stop.done = True
    _restore_mode()
sys.exit(rc)
