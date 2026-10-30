#!/usr/bin/env python3
"""ptyline.py — prove the engine's in-place status line never exceeds the window.

Runs live_line (from engine/slipmat-video) inside a 60-column pseudo-terminal
and prints each frame's visible length: every frame must be ONE row of at most
59 characters, the long ones ending in "…". No rip, no network.

    python3 tools/ptyline.py            # from the repo root
"""
import os, pty, re, select, struct, fcntl, termios, time, sys

COLS = 60
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
engine = os.path.join(root, "engine", "slipmat-video")
script = r'''
C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'; B_V='|'
eval "$(sed -n '/^live_line() {/,/^}/p; /^live_line_end()/p' "$1")"
live_line "${C_CYAN}short${C_RESET} line · 0:12 · 4MB"
sleep 0.1
live_line "stopping · sealing the capture into one mp4 — keys are off until it is done (closing the window abandons it) and more"
sleep 0.1
live_line "$(printf '%s%s%s probing %s' "$C_CYAN" "$B_V" "$C_RESET" "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")" ""
sleep 0.1
live_line_end
'''
pid, fd = pty.fork()
if pid == 0:
    os.execvp("/bin/bash", ["/bin/bash", "-c", script, "ptyline", engine])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, COLS, 0, 0))
out = b""
t0 = time.time()
while time.time() - t0 < 5:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        out += d
os.waitpid(pid, 0)
bad = 0
for f in out.decode("utf-8", "replace").split("\r\x1b[K")[1:]:
    vis = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", f)
    flag = "" if len(vis) < COLS and "\n" not in vis else "   <-- WIDER THAN THE WINDOW"
    if flag:
        bad += 1
    print(f"{len(vis):3d} chars | {vis!r}{flag}")
print("ok: every frame fits" if not bad else f"FAIL: {bad} frame(s) wider than {COLS} columns")
sys.exit(1 if bad else 0)
