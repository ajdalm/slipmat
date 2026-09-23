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
ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of csv=p=0 "<the file>"
printf '\n\nn\n' | ./slipmat hello                             # onboarding, defaults, suite declined
printf '\n\n\nh\n\n' | SLIPMAT_HELLO_NO_OPEN=1 ./slipmat hello # full install path headless:
                                                               # signs for real, opens nothing
./shortcuts/make-shortcuts.sh /tmp/sc-test                     # 4 signed .shortcut files
osacompile -o /tmp/launch-check.scpt shortcuts/launch.applescript   # launcher compiles
```

Local-file tests: encodes land BESIDE the source; row 0 ("keep") must write
nothing and leave the source checksum unchanged (`md5` before/after).
