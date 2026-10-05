# Testing slipmat

The engines are exercised by small, rebuildable harnesses — no network needed
for most of it. Ground rules first:

- **Never wrap the engine in `script`(1)/pty recorders for logging** — on
  Ctrl-C the pty tears and ffmpeg dies mid-finalize, corrupting live captures.
- **Never pipe the download or live capture; never trap INT** in the video
  engine — Ctrl-C must finalize the file, not kill the writer mid-write.
- Simulated Ctrl-C = process-group INT with the pty master held open. A job
  started with `&` from a script inherits SIGINT as *ignored* (POSIX), so
  yt-dlp never sees the interrupt there — launch through a pty, or reset the
  disposition first (`python3 -c 'import os,signal,sys;
  signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' engine/slipmat-video …`).

## The smoke battery — run it before every commit

```bash
./slipmat smoke        # ~10 s, offline; -k keeps the scratch folder, -v prints engine output under a FAIL
```

`tools/smoke.sh` builds three synthetic clips (clean vp9 · rotated h264 with a
Display Matrix · a clip missing 30% of its frames with the survivors' timestamps
kept), runs the real engine on them under a throwaway HOME, and prints one line
per check. The checks are rules that once broke in the field:

- every script parses (`bash -n`)
- `--concurrent-fragments` / `--retry-sleep` stay out of the download code
- the engine recognizes yt-dlp's "Interrupted by user" (Ctrl-C = step down a rung, not a CDN error)
- your `SLIPMAT_EMBED_HOSTS` are never named in a run log whose source is elsewhere (sweeps your own logs written since the engine last changed; read-only)
- BEST on vp9 produces hevc, prints no size heads-up, and every probed value is comma-free
- the stutter detector flags the broken-PTS clip and the CFR fix produces hevc
- z-batch on the rotated clip produces hevc, reads codec and frame rate clean, and describes the frame as *shown* (`360p`, not `360p (V)`)
- every run logged under the throwaway HOME

All green writes `~/.slipmat/last-green` (ffmpeg + yt-dlp versions); `slipmat doctor`
shows it beside the live versions, so a `brew upgrade` that changed something
underneath is one line away. A ruling that can be checked belongs here as an
assertion — that is how drift stops.

## Offline encode fixture (no network)

```bash
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=duration=8:size=640x360:rate=30 \
  -f lavfi -i sine=frequency=440:duration=8 -c:v libvpx-vp9 -b:v 200k -c:a libopus /tmp/fix.webm
ffmpeg -hide_banner -loglevel error -y -i /tmp/fix.webm -c copy /tmp/fix.mkv
SLIPMAT_LOCAL_MKV=/tmp/fix.mkv ./engine/slipmat-video "https://example.test/x" max auto
# expect: vp9 → HEVC conversion, bar to 100%, a receipt, a run log in ~/.slipmat/logs/
```

## Rotated phone video (ffprobe 8 trailing-comma regression, 10.5.26)

(`slipmat smoke` builds this clip and asserts both the comma fix and the
rotation-aware dimensions; the recipe stays here for hand checks.)

Portrait/rotated phone recordings carry a Display Matrix. ffprobe 8 prints that nested
section as an EMPTY trailing csv field (`h264,` `60/1,`), which once broke every local
re-encode ("'h264,' can't live in mp4", "Invalid framerate value: 18807/407,"). The engines
read ffprobe through `ffprobe_csv`, which strips it. Re-check after any ffmpeg upgrade:

```bash
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=duration=4:size=360x640:rate=30 \
  -f lavfi -i sine=frequency=440:duration=4 -c:v libx264 -pix_fmt yuv420p -c:a aac /tmp/rot0.mp4
ffmpeg -hide_banner -loglevel error -y -display_rotation 90 -i /tmp/rot0.mp4 -c copy /tmp/rot.mp4   # input option: stamps the matrix
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 /tmp/rot.mp4
# raw ffprobe 8 prints "h264,360,640," — the trailing comma is the bug the wrapper absorbs
./slipmat z-batch /tmp/rot.mp4
# expect: a [Z] output beside it, codec hevc, no "Invalid framerate" — and NO comma inside any
# value in the run log (grep -n ',p (\|h264,\|/[0-9]*,' ~/.slipmat/logs/<day>/*rot*)
```
A real 8 s cut of a defective iPhone screen recording lives privately at
`~/.slipmat/fixtures/rotated-phone-8s.MP4` (stutter 9.93%, rotation 90): the full z-auto path on it
took 0:25 and landed a 1918x1018 crop.

## Driving interactive flows (STUDIO, the picker)

`tools/ptydrive.py` answers each prompt when its text appears (a pre-fed Enter
would land during the probe and skip it by design):

```bash
python3 tools/ptydrive.py /tmp/run.raw 120 -- "<file>" studio -- \
  'downscale \[Enter = keep\]' '\n' 'recipe \[Enter = ' '4\n'
tr '\r' '\n' < /tmp/run.raw | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tail -40
```

Point it at a different engine with `SLIPMAT_ENGINE=/path/to/engine`.

## Quick spots after a change

```bash
bash -n engine/slipmat-video && bash -n engine/slipmat-audio   # syntax
./slipmat video  "/no/such/file.mp4" studio                    # honest die
# an output name the filesystem rejects dies with a plain cause (never hangs):
#   extract uniquify() into a scratch script, call it with a stem holding "/" and
#   with a 252-byte stem — both return empty at once
# hello on a config with NO final newline: the managed block still sources clean
#   (printf 'USE_COOKIES=0' > $H/.slipmat/config, run hello, bash -n the result)
./slipmat doctor                                               # toolchain
./slipmat video  "<any short YouTube url>" best                # end to end
./slipmat audio  "<any YouTube url>"                           # 320k + square art:
./slipmat spotify "<a Spotify track link>"                     # rerun it: "Already ripped per ledger"
./slipmat spotify --login                                      # "already logged in" once saved
ffprobe -v error -show_entries format_tags=composer -of csv=p=0 "<the file>"   # source stamp
ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of csv=p=0 "<the file>"
# hello: ALWAYS a fake HOME (it writes ~/.slipmat/config) + NO_OPEN (no real
# "Add Shortcut" pop-ups, no Spotify login), driven in a pty, then LOOK at it:
H=$(mktemp -d); HOME=$H SLIPMAT_HELLO_NO_OPEN=1 SLIPMAT_NO_FX=1 \
  SLIPMAT_ENGINE=$PWD/tools/hello.sh python3 tools/ptydrive.py /tmp/h.raw 30 -- -- \
  'Enter = ~/Downloads' '\n' 'Enter = Slipmat' '\n' 'Enter = log in' '\n' \
  'good part' '\n' 'Enter = install' '\n' 'Enter = last step' '\n' \
  'Enter = yes' 'h\n' 'Enter = got it' 'n\n' 'Enter = finish' '\n'
python3 tools/render.py /tmp/h.raw /tmp/h.html 112             # every page, every chip
# ('Enter = log in' appears only when uv is installed and no Spotify login is saved)
./shortcuts/make-shortcuts.sh -c /tmp/sc-test                  # 6 signed .shortcut files (5 without -c)
osacompile -o /tmp/launch-check.scpt shortcuts/launch.applescript   # launcher compiles
```

Local-file tests: encodes land BESIDE the source; row 0 ("keep") must write
nothing and leave the source checksum unchanged (`md5` before/after).

## Failure receipts, signal deaths, output-folder guard

Always under a fake HOME (`H=$(mktemp -d); mkdir -p $H/.slipmat;
printf 'OUTDIR=%s/out\n' "$H" > $H/.slipmat/config`), then `rm -rf` that exact path.

```bash
# yt-dlp's ERROR line lands in the receipt AND the run log (no "see above"):
HOME=$H python3 tools/ptydrive.py /tmp/f.raw 90 -- "https://www.youtube.com/watch?v=zzzzzzzzzzz" best --
python3 tools/render.py /tmp/f.raw /tmp/f.html 132; cat $H/.slipmat/logs/*/*failed*.log
# the progress bar still draws in place (stdout untouched): count the frames
tr '\r' '\n' < /tmp/f.raw | grep -c '\[download\]'
# a signal death renames the log: Ctrl-C at the PICKER menu → "✗ closed <title>.log"
HOME=$H python3 tools/ptydrive.py /tmp/i.raw 90 -- "<short YouTube url>" auto -- 'Enter = 1' '' INT@2
# (window close = SIGHUP to the process group → same rename, exit 129)
# guard: an OUTDIR inside the repo falls back to ~/Downloads/SLIPMAT with one "!" line
printf 'OUTDIR=%s\n' "$PWD" > $H/.slipmat/config; HOME=$H ./engine/slipmat-video --doctor
# disk full during re-encode: point WORKROOT at a tiny volume
hdiutil create -size 9m -fs HFS+ -volname vrtiny -o /tmp/tiny.dmg
hdiutil attach -nobrowse /tmp/tiny.dmg   # then WORKROOT=/Volumes/vrtiny/w in the fake config,
# SLIPMAT_LOCAL_MKV=<a ~4MB noisy vp9 mkv> → "re-encode failed — the disk is full (…)"; detach after
```

Instagram story links (`/stories/<user>/<numeric id>/`) must rip THAT item, not
the reel's first one: pick a non-first item from
`yt-dlp --cookies-from-browser firefox -J https://www.instagram.com/stories/<user>/`,
convert its shortcode to the numeric id, rip it — expect `[<that shortcode>]`,
`IG@<user>`, and an audio stream. (Fake HOME: symlink
`~/Library/Application Support/Firefox` into it, or cookies stand down.)
