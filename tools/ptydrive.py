#!/usr/bin/env python3
# usage: ptydrive.py OUT.raw TIMEOUT_S -- <engine args...> -- <regex> <answer> [...] [INT@secs]
import os, pty, signal, subprocess, sys, time, threading, re
out = sys.argv[1]; T = float(sys.argv[2]); rest = sys.argv[4:]; sep = rest.index('--')
args = rest[:sep]; steps = rest[sep+1:]
m, s = pty.openpty()
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
