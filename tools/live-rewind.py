#!/usr/bin/env python3
# live-rewind.py — yt-dlp, plus a rewind window on a YouTube livestream.
#
# yt-dlp's --live-from-start already contains "start N seconds behind the live
# head": its YouTube fragment generator refuses to reach back past MAX_DURATION
# (120 hours, the most YouTube keeps) and, when the stream is older than that,
# begins at head − MAX_DURATION. That constant is the whole rewind window. This
# wrapper swaps it for SLIPMAT_LIVE_BACK seconds and then runs yt-dlp as usual.
# A stream younger than the window starts from its first fragment, i.e. from
# the start. Unset / 0 = plain yt-dlp (with --live-from-start = from the start).
#
# The constant is found by value, never by position; if a yt-dlp update moves or
# renames it, this exits 86 with one line and the engine falls back honestly.
import os, sys

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
sys.exit(yt_dlp.main())
