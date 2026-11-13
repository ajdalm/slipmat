#!/usr/bin/env python3
# catchup.py — a live playlist that keeps its history, recorded by sequence number.
#
# A rewind used to be ffmpeg reading the playlist from an older piece: one piece
# at a time, the whole (long) playlist re-read between pieces. Measured on a
# four-hour window at 1080p: about three times real time, so two hours to reach
# live. The pieces themselves come at line speed (two seconds of video in a tenth
# of a second), so this fetches the backlog several at a time, writes them IN
# ORDER into one MPEG-TS file, and once it is at the live head keeps recording
# the same way, piece by piece as they are listed. Nothing is ever skipped: the
# next piece is always the next sequence number.
#
# It only takes a playlist it fully understands, and it gives the capture back
# the moment it does not:
#   exit 4  declined, nothing written: not a plain media playlist of MPEG-TS
#           pieces (a key, a byte range, an init section, a master), or a
#           discontinuity inside the stretch to fetch.
#   exit 3  handed over: a piece or the playlist would not come after its
#           retries, a discontinuity appeared, a piece was not MPEG-TS. Every
#           whole piece so far is in <out>.catchup.part and the state file names
#           the next sequence number; the caller's one-piece-at-a-time recorder
#           starts there.
#   exit 0  stopped (the first interrupt) or the stream ended: <out> is the file.
# A piece that has already left a sliding window cannot be fetched by anyone; the
# recording begins at the oldest piece still listed and the state says how much
# that was.
#
# record(...) is called by live-rewind.py, which owns the stop (the first Ctrl-C
# or x x arrives here as KeyboardInterrupt). Standalone, for tests:
#   catchup.py <playlist address> <start index> <out file> <state file> [lag file]
# start index: 0 = the oldest piece listed, -K = K pieces from the end.
# Environment: SLIPMAT_CATCHUP_WORKERS (6) · SLIPMAT_CATCHUP_FAIL_AFTER=<pieces>
# (tests: the next piece after that many fails for good) · SLIPMAT_CATCHUP_UNTIL
# =live (tests: stop by itself on reaching the head).
import http.client, json, os, re, sys, threading, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

UA = 'Python-urllib/%d.%d' % sys.version_info[:2]     # this client, under its own name
HAND = 0            # pieces left to the live edge before the backlog counts as caught up
SLOPE_S = 120       # the window the "to go" guess is measured over


class Decline(Exception):
    pass


class HandOver(Exception):
    pass


def _get(url, headers, timeout=20, limit=64 * 1024 * 1024):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(limit)


def read_playlist(url, headers):
    """→ dict(first, pieces=[(seq, address, seconds, discontinuity_before)], ended, target)"""
    txt = _get(url, headers).decode('utf-8', 'replace')
    if '#EXTM3U' not in txt or '#EXT-X-STREAM-INF' in txt:
        raise Decline('not a media playlist')
    for tag in ('#EXT-X-BYTERANGE', '#EXT-X-MAP'):
        if tag in txt:
            raise Decline(tag[7:].lower() + ' in the playlist')
    for m in re.finditer(r'#EXT-X-KEY:([^\n]*)', txt):
        if 'METHOD=NONE' not in m.group(1):
            raise Decline('the pieces are encrypted')
    m = re.search(r'#EXT-X-MEDIA-SEQUENCE:\s*(\d+)', txt)
    seq = int(m.group(1)) if m else 0
    first = seq
    m = re.search(r'#EXT-X-TARGETDURATION:\s*(\d+)', txt)
    target = int(m.group(1)) if m else 4
    pieces, dur, disc = [], None, False
    for line in txt.splitlines():
        line = line.strip()
        if line.startswith('#EXTINF:'):
            try:
                dur = float(line[8:].split(',')[0])
            except ValueError:
                dur = float(target)
        elif line.startswith('#EXT-X-DISCONTINUITY') and not line.startswith('#EXT-X-DISCONTINUITY-SEQUENCE'):
            disc = True
        elif line and not line.startswith('#'):
            if dur is None:
                raise Decline('a piece with no length')
            pieces.append((seq, urllib.parse.urljoin(url, line), dur, disc))
            seq += 1
            dur, disc = None, False
    if not pieces:
        raise Decline('no pieces listed')
    return {'first': first, 'pieces': pieces, 'ended': '#EXT-X-ENDLIST' in txt, 'target': target}


class Fetcher:
    """one keep-alive connection per worker thread; a fresh one after any error"""
    def __init__(self, headers):
        self.headers = headers
        self.local = threading.local()

    def _conn(self, parts):
        c = getattr(self.local, 'conn', None)
        key = (parts.scheme, parts.netloc)
        if c is None or getattr(self.local, 'key', None) != key:
            cls = http.client.HTTPSConnection if parts.scheme == 'https' else http.client.HTTPConnection
            c = cls(parts.netloc, timeout=20)
            self.local.conn, self.local.key = c, key
        return c

    def piece(self, url):
        """→ bytes; raises FileNotFoundError on 404/410, IOError on anything else"""
        parts = urllib.parse.urlsplit(url)
        path = parts.path + ('?' + parts.query if parts.query else '')
        last = None
        for attempt in range(4):
            try:
                c = self._conn(parts)
                c.request('GET', path, headers=self.headers)
                r = c.getresponse()
                body = r.read()
                if r.status in (404, 410):
                    raise FileNotFoundError(url)
                if r.status != 200:
                    raise IOError('HTTP %d' % r.status)
                want = r.getheader('Content-Length')
                if want is not None and int(want) != len(body):
                    raise IOError('short read')
                if not body or body[0] != 0x47:
                    raise ValueError('not MPEG-TS')
                return body
            except (FileNotFoundError, ValueError):
                raise
            except Exception as e:
                last = e
                try:
                    self.local.conn.close()
                except Exception:
                    pass
                self.local.conn = None
                time.sleep(0.5 * (2 ** attempt))
        raise IOError(str(last))


class Lag:
    def __init__(self, path):
        self.path, self.hist = path, []

    def write(self, behind):
        if not self.path:
            return
        now = time.time()
        behind = max(0, int(behind))
        self.hist.append((now, behind))
        while self.hist and now - self.hist[0][0] > SLOPE_S:
            self.hist.pop(0)
        t0, b0 = self.hist[0]
        eta = -1
        if now - t0 >= 20 and b0 > behind:
            eta = int(behind / ((b0 - behind) / (now - t0)))
        try:
            with open(self.path + '.tmp', 'w') as fh:
                fh.write('audio %d %d\nvideo %d %d\n' % (behind, eta, behind, eta))
            os.replace(self.path + '.tmp', self.path)
        except OSError:
            pass


def record(url, start_index, out, state_path, lag_path='', headers=None, workers=None):
    headers = dict(headers or {})
    headers.setdefault('User-Agent', UA)
    workers = workers or int(os.environ.get('SLIPMAT_CATCHUP_WORKERS', '6') or 6)
    fail_after = int(os.environ.get('SLIPMAT_CATCHUP_FAIL_AFTER', '0') or 0)
    until_live = os.environ.get('SLIPMAT_CATCHUP_UNTIL', '') == 'live'
    part, handed = out + '.part', re.sub(r'\.[^.]+$', '', out) + '.catchup.part'
    st = {'why': '', 'detail': '', 'start_seq': None, 'next_seq': None, 'pieces': 0, 'seconds': 0.0, 'bytes': 0,
          'expired_pieces': 0, 'expired_seconds': 0.0, 'reached_live': False, 'file': ''}

    def save(why, detail=''):
        st['why'], st['detail'] = why, detail
        try:
            with open(state_path + '.tmp', 'w') as fh:
                json.dump(st, fh)
            os.replace(state_path + '.tmp', state_path)
        except OSError:
            pass

    def playlist():
        last = None
        for attempt in range(6):
            try:
                return read_playlist(url, headers)
            except Decline:
                raise
            except Exception as e:
                last = e
                time.sleep(min(8, 1 * (2 ** attempt)))
        raise HandOver('the playlist would not come (%s)' % last)

    try:
        pl = playlist()
    except Decline as e:
        save('declined', str(e))
        return 4
    except HandOver as e:
        save('declined', str(e))
        return 4
    n = len(pl['pieces'])
    i0 = max(0, min(n - 1, start_index if start_index >= 0 else n + start_index))
    if any(p[3] for p in pl['pieces'][i0 + 1:]):
        save('declined', 'a discontinuity inside the stretch to fetch')
        return 4
    nxt = pl['pieces'][i0][0]
    st['start_seq'] = st['next_seq'] = nxt
    lag, fetch = Lag(lag_path), Fetcher(headers)
    fh = open(part, 'wb')
    pool = ThreadPoolExecutor(max_workers=workers)
    rc, why, detail = 0, 'stopped', ''
    gone_at = {}
    try:
        while True:
            by = {p[0]: p for p in pl['pieces']}
            head = pl['pieces'][-1][0]
            if nxt < pl['first']:                      # left the window before it could be fetched
                gone = pl['first'] - nxt
                st['expired_pieces'] += gone
                st['expired_seconds'] += gone * float(pl['pieces'][0][2])
                nxt = pl['first']
            todo = [by[s] for s in range(nxt, head + 1 - HAND) if s in by]
            if not todo:
                if pl['ended']:
                    why = 'ended'
                    break
                st['reached_live'] = True
                lag.write(0)
                if until_live:
                    why = 'live'
                    break
                time.sleep(min(2.0, max(0.5, pl['target'] / 2.0)))
                pl = playlist()
                continue
            if any(p[3] for p in todo if p[0] != st['start_seq']):
                raise HandOver('the stream restarted (a discontinuity in the playlist)')
            read_at = time.time()
            behind_all = sum(p[2] for p in todo)
            batch = todo[:workers * 4]                 # then the playlist is read again (the head moves)
            futs = [(p, pool.submit(fetch.piece, p[1])) for p in batch]
            done_s = 0.0
            for p, f in futs:
                if fail_after and st['pieces'] >= fail_after:
                    for _, g in futs:
                        g.cancel()
                    raise HandOver('a piece would not come (test)')
                try:
                    body = f.result()
                except FileNotFoundError:
                    for _, g in futs:
                        g.cancel()
                    gone_at[p[0]] = gone_at.get(p[0], 0) + 1
                    if gone_at[p[0]] >= 3:               # still listed, never there: not this recorder's to guess at
                        raise HandOver('a listed piece is not on the server')
                    time.sleep(1)
                    break                                # gone from the window: the next read of the playlist says how much
                except ValueError:
                    for _, g in futs:
                        g.cancel()
                    raise HandOver('a piece is not MPEG-TS')
                except Exception as e:
                    for _, g in futs:
                        g.cancel()
                    raise HandOver('a piece would not come (%s)' % e)
                fh.write(body)
                nxt = p[0] + 1
                done_s += p[2]
                st['next_seq'] = nxt
                st['pieces'] += 1
                st['seconds'] += p[2]
                st['bytes'] += len(body)
                lag.write(behind_all - done_s + (time.time() - read_at))
            fh.flush()
            save('recording')
            pl = playlist()
    except KeyboardInterrupt:
        why = 'stopped'
    except HandOver as e:
        rc, why, detail = 3, 'handover', str(e)
    except Exception as e:                              # anything unforeseen: what is whole is kept and handed over
        rc, why, detail = 3, 'handover', 'the fast recorder stopped (%s: %s)' % (type(e).__name__, e)
    finally:
        try:
            pool.shutdown(wait=False, cancel_futures=True)
        except TypeError:
            pool.shutdown(wait=False)
        try:
            fh.flush()
            os.fsync(fh.fileno())
        except OSError:
            pass
        fh.close()
    try:
        if rc == 0:
            os.replace(part, out)
            st['file'] = out
        else:
            os.replace(part, handed)
            st['file'] = handed
    except OSError as e:
        detail = (detail + ' · ' if detail else '') + 'could not rename the capture (%s)' % e
        st['file'] = part
    save(why, detail)
    return rc


if __name__ == '__main__':
    if len(sys.argv) < 5:
        sys.stderr.write('usage: catchup.py <playlist address> <start index> <out file> <state file> [lag file]\n')
        sys.exit(2)
    sys.exit(record(sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5] if len(sys.argv) > 5 else ''))
