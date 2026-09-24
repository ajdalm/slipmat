# Testing slipmat

The engines are exercised by small, rebuildable harnesses — no network needed
for most of it. Ground rules first:

- **Never wrap the engine in `script`(1)/pty recorders for logging** — on
  Ctrl-C the pty tears and ffmpeg dies mid-finalize, corrupting live captures.
- **Never pipe the download or live capture; never trap INT** in the video
  engine — Ctrl-C must finalize the file, not kill the writer mid-write.
- Simulated Ctrl-C = process-group INT with the pty master held open.

## Offline encode fixture (no network)

```bash
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=duration=8:size=640x360:rate=30 \
  -f lavfi -i sine=frequency=440:duration=8 -c:v libvpx-vp9 -b:v 200k -c:a libopus /tmp/fix.webm
ffmpeg -hide_banner -loglevel error -y -i /tmp/fix.webm -c copy /tmp/fix.mkv
SLIPMAT_LOCAL_MKV=/tmp/fix.mkv ./engine/slipmat-video "https://example.test/x" max auto
# expect: vp9 → HEVC conversion, bar to 100%, a receipt, a run log in ~/.slipmat/logs/
```

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
./shortcuts/make-shortcuts.sh /tmp/sc-test                     # 5 signed .shortcut files
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
tr '\r' '\n' < /tmp/yt.raw | grep -c '\[download\]'
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
