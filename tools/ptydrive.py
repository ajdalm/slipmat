#!/usr/bin/env python3
# usage: ptydrive.py OUT.raw TIMEOUT_S -- <engine args...> -- <regex> <answer> [...] [INT@secs | CTRLC@secs | KEY@secs:text]\n# INT@ = SIGINT to the process group (kill); CTRLC@ = the ^C byte typed into the pty (what a key does). PTY_COLS/PTY_ROWS size the pty.
import os, pty, signal, subprocess, sys, time, threading, re
out = sys.argv[1]; T = float(sys.argv[2]); rest = sys.argv[4:]; sep = rest.index('--')
args = rest[:sep]; steps = rest[sep+1:]
m, s = pty.openpty()
if os.environ.get('PTY_COLS'):   # size the pty like a real window (the engine measures chip rows against it)
    import fcntl, struct, termios
    fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack('HHHH', int(os.environ.get('PTY_ROWS', '44')), int(os.environ['PTY_COLS']), 0, 0))
p = subprocess.Popen([os.environ.get('SLIPMAT_ENGINE', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'engine', 'slipmat-video'))] + args, stdin=s, stdout=s, stderr=s, preexec_fn=os.setsid)
os.close(s); buf = bytearray(); lock = threading.Lock(); f = open(out, 'wb')
def pump():
    while True:
        try: d = os.read(m, 4096)
        except OSError: break
        if not d: break
        with lock: buf.extend(d)
        f.write(d); f.flush()
threading.Thread(target=pump, daemon=True).start()
ANSI = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b\][^\x07]*\x07')
def text():
    with lock: t = bytes(buf).decode('utf-8', 'replace').replace('\r', '\n')
    return ANSI.sub('', t)
pos = 0; i = 0
while i < len(steps):
    st = steps[i]; i += 1
    if st.startswith('INT@'):
        time.sleep(float(st[4:])); os.killpg(os.getpgid(p.pid), signal.SIGINT); continue
    if st.startswith('CTRLC@'):   # a real Ctrl-C keypress: the byte goes through the pty's line discipline (VINTR)
        time.sleep(float(st[6:])); os.write(m, b'\x03'); continue
    if st.startswith('KEY@'):   # KEY@secs:text — keys typed into the pty, escapes allowed (KEY@5:x · KEY@5:\x1b[B = the ↓ arrow)
        secs, _, txt = st[4:].partition(':'); time.sleep(float(secs)); os.write(m, txt.encode().decode('unicode_escape').encode('latin-1')); continue
    rx = st; ans = steps[i].encode().decode('unicode_escape'); i += 1
    t0 = time.time(); ok = False
    while time.time() - t0 < T:
        mm = re.search(rx, text()[pos:])
        if mm: pos += mm.end(); ok = True; break
        if p.poll() is not None: break
        time.sleep(0.3)
    if not ok: print(f"TIMEOUT waiting for /{rx}/", file=sys.stderr); break
    time.sleep(0.6); os.write(m, ans.encode())
try: rc = p.wait(timeout=T*4)
except subprocess.TimeoutExpired: os.killpg(os.getpgid(p.pid), signal.SIGINT); rc = p.wait(timeout=60)
time.sleep(1); f.flush(); print("exit:", rc)
