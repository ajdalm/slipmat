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
- the engine recognizes yt-dlp's "Interrupted by user" (a hand interrupt, not a CDN error)
- the keys: `tools/keys.py` compiles and carries the x question; the engine starts the reader before every download and re-encode (`keys_start`), `by_hand` reads the `key.down` flag, the encode reads `key.x`; no rail ever prints a Ctrl-C key
- the live keys: the `x` thread in `live-rewind.py` + `keys.py`, the exit-time terminal restore, the "while it records" rail
- your `SLIPMAT_EMBED_HOSTS` are never named in a run log whose source is elsewhere (sweeps your own logs written since the engine last changed; read-only)
- BEST on vp9 produces hevc, prints no size heads-up, and every probed value is comma-free
- the stutter detector flags the broken-PTS clip and the CFR fix produces hevc
- z-batch on the rotated clip produces hevc, reads codec and frame rate clean, and describes the frame as *shown* (`360p`, not `360p (V)`)
- every run logged under the throwaway HOME

All green writes `~/.slipmat/last-green` (ffmpeg + yt-dlp versions); `slipmat doctor`
shows it beside the live versions, so a `brew upgrade` that changed something
underneath is one line away. A ruling that can be checked belongs here as an
assertion — that is how drift stops.

## The version number

The engine prints one number (`SLIPMAT 4.11` on the first line of every run
and run log, `VERSION=` in `engine/slipmat-video`). It continues the count of
the private tool slipmat grew out of, which is why it starts above 4. There is
no second release number: a "slipmat vN" in notes or chat names a round of
work, not a code version.

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
rotation-aware dimensions; the recipe stays here for hand checks.) ffprobe 9.0.2, on the
reference Mac since 11.6.26, prints the same trailing comma; the wrapper stays.

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

## The asks (10.12.26): one line per question, keys as chips

Every question the engine asks is one line: the question, then each key as a
keycap chip glued to what it does, the cursor at the end — `re-encode anyway?
[Enter] keep lossless  [y] re-encode  ›`. Enter is always the safe way out.
`chip_line` builds the line; `ask_yn` / `ask_line` still read and log the answer
(the run log keeps the stripped line and the answer). The six asks and what they do:

| screen | the line | Enter | the other key |
|---|---|---|---|
| STUDIO on a live stream, after the capture is sealed | `re-encode the capture?` | keep as is | `y` smaller HEVC |
| STUDIO, the dial will not shrink the file | `re-encode anyway?` | keep lossless | `y` re-encode |
| STUDIO, the encode came out no smaller | `keep the re-encode?` | no, keep only the original | `y` keep both |
| STUDIO end, an original was kept | `delete the original?` | keep both | `y` delete it — to the Trash, never `rm` |
| PICKER `c`, a stream id with a catch | `keep your pick?` | the Best MP4 (row 1, named) — the line counts down `auto-Enter in 5s … 1s` and silence does the same | `k` keep the custom pick (one key, no Enter) |
| the NMX naming window | `Which show is this?` · `Air date?` | custom (a second Enter = the default name stands) · the feed date | `1 2 3` a show · `3 2 1` the days before the feed date |

Smoke asserts no `[y/N]` prompt is left in the engine, the audio engine, z-batch
or hello. Drive them with ptydrive; the proofs of 10.12.26 ran on a short public
YouTube video (`jNQXAC9IVRw`):

```bash
# asks 2, 3, 4 — STUDIO, custom q95 (bigger than the source on purpose)
HOME=/tmp/fakehome python3 tools/ptydrive.py /tmp/a.raw 240 -- '<url>' studio -- \
  '\[Enter = 1\]' '\n' 'recipe \[Enter = ' 'c\n' 'custom ›' '95\n' \
  're-encode anyway\?' 'y\n' 'keep the re-encode\?' 'y\n' 'delete the original\?' 'y\n'
# ask 5 — PICKER (`auto` on the command line), c, a vp9 id; 'k' alone keeps, '\n' or nothing = Best MP4
HOME=/tmp/fakehome python3 tools/ptydrive.py /tmp/b.raw 120 -- '<url>' auto -- \
  '\[Enter = 1\]' 'c\n' 'type a video ID' '242\n' 'keep your pick\?' 'k'
```

The NMX window is a generated script; test it without a rip by extracting the
heredoc (`sed -n '/cat > "$QDIR\/quiz.sh" <<QEOF/,/^QEOF$/p'`), running it with
`QDIR OUTDIR WORKDIR NAME _qdef _qshows NMX_SHOWS_LEARNED` set, and driving
`quiz.sh` in a pty.

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

## Livestreams (network; hand tests, not in smoke)

A live YouTube URL with no window word asks where the capture should start
(`ask_live_start`; since 4.32 so does any stream whose playlist keeps its
history, see below); the words `from-start` / `last-2h` / `last-90m` on the
command line pre-answer it. Both capture paths run through
`tools/live-rewind.py`: yt-dlp in-process, the rewind window swapped into
yt-dlp's 120 h constant, and a SIGINT handler that makes the FIRST Ctrl-C the
stop and disarms the terminal's interrupt key until the file is sealed.

Proofs (10.5.26 eve, a 24/7 news stream; `PTY_COLS=104` sizes the pty like the
BEST window so the chip rows are measured for real):

```
# 1. the ask, answered "2" (10 min back), then TWO Ctrl-C's one second apart:
#    ONE merged h264/aac mp4 ≈ 10.5 min, no .fNNN halves beside it, a full receipt,
#    the log says "? where should the capture start? → 2 (last 10m)" and
#    "stopped by Ctrl-C … later presses were disarmed"
HOME=$H PTY_COLS=104 python3 tools/ptydrive.py /tmp/l1.raw 120 -- '<live url>' max best -- \
  'capture start' '2\n' INT@40 INT@41
# 2. the timer: no answer, the capture starts from now after 8 s; two Ctrl-C's → one playable mp4
HOME=$H PTY_COLS=104 python3 tools/ptydrive.py /tmp/l2.raw 120 -- '<live url>' best -- INT@30 INT@31
# 3. a replay with a window word: the tail is cut and the name says so
HOME=$H slipmat video '<a 3 h replay of an ended stream>' 720 auto last-5m
#    → "this stream already ended — taking the last 5m of the 3:46:03 replay", a file ≈ 300 s
#      named "… (last 5m) [id] - …"
# then LOOK: cat /tmp/l1.raw in a Terminal tab — the question, two aligned chip rows, Enter row
```

### A live playlist that keeps its history (11.12.26, Rumble): rewind on any site

A live HLS playlist usually lists its last few pieces. Some sites list far more:
a Rumble broadcast's playlist starts at sequence 1 and holds every piece since
the stream began; a 24/7 stream there holds its last 4 hours (a sliding window).
ffmpeg starts three pieces from the end unless told otherwise, so a capture
there began at "now". `hls_history` reads the playlist once (a plain fetch with
the headers the probe recorded) and the capture hands ffmpeg the piece to begin
at (`-live_start_index`, per input): 0 for from-start, K pieces from the end
for a last-N window (12 s of margin), three pieces in on a sliding window.

- with no window word, in a terminal, the question appears when the playlist
  holds 90 s or more: `this is a livestream, on air for 9:34 — where should the
  capture start?` (a sliding window reads `(its last 3:59:58 can be rewound)`).
- one stream, so one distance under the REC line, computed by
  `tools/live-rewind.py` from ffmpeg's own progress file:
  `↳ catching up · 6:18 behind live, ~2m to go · stop now = the file ends 6:18 short of live`,
  then `↳ rewind caught up · the capture is live now`.
- a stop while it is behind is said on the receipt:
  `stop    stopped 6:08 short of live — video and audio end together`.
- a window longer than the stream: `this stream has been on air for only … —
  recording it from its start`. A sliding window asked from the start:
  `this site keeps the last 3:59:58 of the stream, not its start — the capture
  begins there`, and the receipt reads `from 3:59:58 back`.
- no history (a playlist under 90 s, no playlist, an ended one, a picked stream
  that is not a playlist): one line saying so, and the capture runs from now.

Proofs (11.12.26, two live Rumble streams; the run log carries
`live playlist history: <s> listed, first sequence <n>` and
`playlist rewind: format … · start index …`):

```
# 1. the question answered 0 (from start), x x after 50 s: a 9:34-old stream, 4:25 in
#    the file, receipt "stopped 6:08 short of live"
HOME=$H PTY_COLS=104 python3 tools/ptydrive.py /tmp/r1.raw 120 -- '<live rumble url>' max best -- \
  'capture start' '0\n' KEY@50:x KEY@2:x
# 2. last-5m run until "rewind caught up", x x: 5:13 back + 1:25 of wall clock = 6:33 in the file
HOME=$H PTY_COLS=104 python3 tools/ptydrive.py /tmp/r2.raw 120 -- '<live rumble url>' 360 auto last-5m -- KEY@85:x KEY@2:x
# 3. a 24/7 stream, from-start: the sliding-window sentence, "from 3:59:58 back"
HOME=$H PTY_COLS=104 python3 tools/ptydrive.py /tmp/r3.raw 120 -- '<24/7 rumble url>' 360 auto from-start -- KEY@28:x KEY@2:x
```

`slipmat smoke` 3c6 runs `hls_history` offline on three written playlists (whole,
sliding, ended) and asserts each answer.

**A playlist whose pieces carry no media file ending (4.33, 11.12.26).** ffmpeg
7.1.1 and later check every piece address of an HLS playlist against a list of
media endings and refuse the playlist before a byte lands:
`URL … is not in allowed_segment_extensions`, then yt-dlp's
`ffmpeg exited with code 183`. A station's linear channel on amagi.tv lists each
piece as a tracking address that redirects to the `.ts` (`…/beacon/…/1920x1080_5129264?…&redirect_url=…playlist1080p_4614745.ts`),
so every capture of it died in about three seconds. `live_refused_ending` reads
that sentence in the capture's own stderr log; when nothing landed and no stop
was asked, `live_capture` runs the capture once more with `-extension_picky 0`
on every ffmpeg input (the plain `ffmpeg_i` words and the rewind's
`ffmpeg_i1`/`ffmpeg_i2`) and says
`! ffmpeg refused this stream: its pieces are listed under addresses with no media file ending — recording with that one check off`.
A capture that already has a file is never restarted; every other capture keeps
the check.

```
# the sniffed master playlist of a linear channel, 360p, x x after 40 s:
# the refusal line, then REC; 0:53 in the file (h264/aac, start_time 0)
HOME=$H PTY_COLS=104 python3 tools/ptydrive.py /tmp/p1.raw 120 -- '<channel playlist.m3u8>' 360 auto -- KEY@40:x KEY@2:x
```

`slipmat smoke` 3c7 runs `live_refused_ending` on written logs and folders and
asks the installed ffmpeg for the refusal sentence on a written playlist (a
piece named without an ending), with and without the check.

A capture grows in the `_in progress` folder inside the output folder and is
placed beside the finished files when it ends (10.29.26); the folder stays (it is
permanent, so the list never gains or loses that row). Every VOD rip reserves its
name there too (`<name>.mp4.claim`, 0 bytes) and the output folder gains the
finished file only:

```
# x x after 30 s (ptydrive delays are sequential: 30 then 3): while it records,
# `ls "$O/_in progress"` shows the growing .part + the .mp4.claim and nothing new
# in $O; after the seal the mp4 is in $O and the folder holds nothing of it
HOME=$H SLIPMAT_LIVE_ASK=0 PTY_COLS=104 python3 tools/ptydrive.py /tmp/l4.raw 150 -- '<live url>' max best -- KEY@30:x KEY@3:x
# a VOD: during the download `ls "$O/_in progress"` shows only the .mp4.claim,
# `ls "$O"` nothing new; at the end the mp4 is in $O and the claim is gone
HOME=$H slipmat video '<short vod url>' 360 best
```

Every live status line is one in-place line cut to the window (10.29.26; the
old seal line, wider than the window, wrapped and left one row behind per tick —
45 copies on a long seal). The width rule is proven in a narrow pty, no rip
needed: run `python3 tools/ptyline.py` (prints each frame's visible length — at
60 columns every frame is one row of at most 59 characters, the long ones ending
in "…"). On a real capture in a 70-column pty the stop sentence appears ONCE as a
finished line, the row under it reads "✓ sealing · 0:03 · 12MB" and updates in
place, then "✓ captured …" and the DONE box:

```
HOME=$H SLIPMAT_LIVE_ASK=0 PTY_COLS=70 python3 tools/ptydrive.py /tmp/l5.raw 200 -- '<live url>' max best -- KEY@25:x KEY@3:x
```

The finished window closes itself (10.29.26): a throwaway window proves the helper
without a rip — it closes 4 s after the three lines print, silently, and only
that window; typed before that, `x` or Enter closes it at once, any other key keeps it:

```
osascript -e 'tell application "Terminal" to do script "bash -c \"echo test; bash ~/SLIPMAT/tools/window-close.sh 4\""'
```
`slipmat smoke` checks offline that the installed yt-dlp still carries the
rewind hook, that the wrapper still handles SIGINT, that receipts never pick a
per-stream half, and that the ask stays out of z-auto batches.
Since 11.2.26 it also checks that the from-now capture selector accepts
YouTube's HLS-only audio rendition (the live audio no longer comes as m4a; a
selector that insists on it dies with "Requested format is not available"
before a byte lands), and that a merge yt-dlp fails after a whole download is
merged in the scratch instead of fetched again. Since 4.21 (the same evening) it
also feeds the picker a dump that lists a size twice, as a whole file and as
YouTube's unverified HLS copy, and expects the whole file; and it runs the
salvage on a real MPEG-TS half whose packets carry no timestamps when the local
snippet `~/.slipmat/fixtures/yt-hls-untimed.ts` is present.

A rewind shows how far each stream is behind live (11.2.26). The video and the
audio of a rewound capture download as two threads, a fragment at a time; the
audio (tiny fragments) reaches the live head long before the video, so a stop
while the video is still behind ends the picture early with the sound running
on to the stop. `tools/live-rewind.py` wraps yt-dlp's fragment generator and
writes `video <s>` / `audio <s>` (seconds behind the live head) to
`live.lag` in the run's scratch on every fragment, as `video <s> <eta>` /
`audio <s> <eta>` (seconds behind the live head, and seconds until it reaches
live — the lag's slope over the last two minutes, -1 until 20 s of it exist or
while the lag is not shrinking); the engine reads it onto a line of its own
under the REC line (11.2.26 evening — the one-line form read as lingo), both
redrawn in place:
`↳ catching up · video 1:41:30 behind live, ~52m to go · audio 1:39:10 behind live, ~6m to go`,
then `↳ video 24:31 behind live, ~8m to go · audio is live · stop now = video ends 24:31 early`,
then `↳ rewind caught up · video and audio are both live · a stop now ends them together`
(live = within 15 s; "~… to go" appears after the first 20 s). The run log says
where each stood at the stop. The receipt reads the GAP between the two: when
the video ended more than 15 s before the sound it says `stop    the picture
ends 24:31 before the sound`; when both were still far from live and stopped
together (a from-the-start capture of a days-old stream begins 120 h back and
sheds hours of lag per hour) it says `stop    stopped 119:14:13 short of live —
video and audio end together`; `time … recorded` is the picture's own length.
A from-now capture never writes the file. Proven on his clicks (11.2
afternoon): a 480p last-90m rewind logged `video 1471s behind` against the
file's audio − video = 1470 s, a 360p last-2h one 1059 s against 1060 s; a
144p from-the-start capture of the days-old pool feed stopped at 2:17 with
both 429253 s behind and equal 47:55 streams. Hand test (pool feed, the 720
door, a 10-minute rewind, `x x` at 50 s — the line reads `caught up` around
40 s in, the stop lands with both streams within seconds and the
receipt carries no `stop` line):

```
HOME=$H PTY_COLS=110 python3 tools/ptydrive.py /tmp/l6.raw 170 -- '<live url>' 720 auto last-10m -- KEY@50:x KEY@3:x
```

The capture ladder never ends in its cap (11.2.26): a picked row or the 720
door leads every rung by its height, but when nothing at or under that height
is offered the same QuickTime-native pairs run uncapped, then any single file —
the capture lands at what there is (the receipt says `size 1080p — nothing at
or under 720p was offered on this stream`) instead of dying with "Requested
format is not available". `slipmat smoke` proves it offline through yt-dlp's
own selector on a stream offering only 1080 video + audio, and proves the lag
file through a fake fragment generator under the real wrapper. Note: the word
`best` on the command line means the top quality by design (`RES=max`), so a
capped live proof uses `720 auto` or a picked row, never `720 best`.

## A download that dies at the merge (11.2.26)

yt-dlp downloads split video and audio as two whole files and merges them at
the end. When that merge fails it prints only ffmpeg's last line
("Postprocessing: Conversion failed!"), and the two halves sit finished in the
scratch with no `.part` beside them. The engine now merges them itself
(timestamps regenerated, ffmpeg's words kept in the run log under
`salvage merge`) and carries on to the stutter test; the receipt notes it. The
blank-page manifest swap fires only when nothing at all was downloaded, so a
failed merge never re-downloads the show. Offline proof: `slipmat smoke` feeds
two whole halves and yt-dlp's words into the salvage and expects one mkv with
both streams.

The same evening the cause of the El-Sayed failure (a 60 Minutes interview,
1:05:31) turned out to sit upstream of the merge. yt-dlp 2026.10.26 lists
YouTube's HLS copy of every DASH size beside the whole file (`Untested` in
`-F`; yt-dlp itself ranks them last), and the picker, choosing by bitrate,
took the copy at 720, 480 and 360 in a row. Its MPEG-TS video half carries one
packet per fragment with no timestamp at all; matroska refuses such a packet
even with regenerated timestamps, so yt-dlp's merge and the salvage both died
and the ladder blamed the CDN. Two rules since 4.21: the picker ranks an
unverified rendition last and, at the same size, a whole file over a playlist
of pieces (YouTube is back on its DASH files, the fast path); and the salvage
has a third route, by way of an mp4 (mp4 stamps the packet), proven on the
real halves (117,815 frames, 1:05:31, both streams). A ladder that ends on a
merge death now says so instead of calling it a CDN wall. `slipmat smoke` 3c4
and 3c5 cover both rules offline.

## Ended streams still being finished by YouTube (post_live, 10.13.26)

After a live stream ends, YouTube shows the page as `post_live` for minutes to many
hours: the replay is complete (every fragment listed, duration known) but the normal
video page is not built yet. slipmat downloads it as a normal file — the SOURCE box
says `ended · replay ready`, one line explains it, no capture question, no REC clock.
A window word (`last-1h`, `from-start`) is set aside with a line: the cut rides ffmpeg
over the manifest and the unfinished page refuses it (exit 183); the replay comes whole.
A `post_live` page with NO video streams is limbo proper: the engine stops with a plain
"not published yet, try later". Once YouTube finishes (`was_live`), everything is a
normal video again, cuts included.

Speed: such a replay is ~2,400 pieces per track and YouTube serves one connection at
about 1 MB/s, so a 3-hour 720p took 26 minutes one piece at a time. On YouTube fragmented
replays — and only there — the engine fetches 8 pieces at once (`DLPAR="-N 8"`, config
`SLIPMAT_YT_PIECES`, 0 = off); the screen says `YouTube hands this replay over in 2429
pieces per track — fetching 8 at a time`. The parallel-pieces ban stands everywhere else
(the Newsmax CDN answers parallel grabs with 503s); smoke asserts `-N` appears only inside
that gate. Measured 10.13 on 720p pieces: 1 at a time 1.3 pieces/s · 4 at a time 3.5/s.
`x x` mid-download under parallel pieces cancels clean (exit 130, nothing kept).
Sixteen at a time measured 18.5 pieces/s but a full run died on yt-dlp's own thread race
(`No such file or directory: …part-FragNNN`), so 8 is the ceiling; it showed once at 8
too. When it shows, `pieces_backoff` halves the pieces (8 → 4 → 2 → one) and STARTS THE
FETCH OVER: a resume from yt-dlp's state after that race landed a file with every
timestamp but only 56% of its frames (204,246 of 363,988) — holes a duration check
cannot see. So every pieces replay is frame-counted before it is handed over
(`replay_holes`: packets vs duration × `r_frame_rate` — not `avg_frame_rate`, which is
frames/duration and hides holes); under 98% → clean re-fetch with fewer pieces, three
tries, then an honest die. The receipt's got-line adds `· 99% of frames` on these.
Full 240p (3:22) at 8: 496M in 1:28, complete, 99% of frames.

Fixture pair for the gate (10.13, scratch): the clean 240p (363,988 packets) reads
whole 99%; the holey resume reads 56%.

STUDIO on such a replay suggests `keep` (Enter), not "back to PICKER": a re-rip would
fetch every piece again.

The receipt answers "did I get it all?": on every replay (post_live / was_live) a `got`
line compares the file to the source length (`got 3:22:21 of 3:22:23 — complete`); more
than 15 s missing, or any piece the site skipped, prints the shortfall in yellow
(`got 2:38:10 of 3:22:23 — 44:13 missing · 3 pieces skipped by the site`) on any URL rip.

```bash
# live proof (needs a post_live video; the rally of 10.12.26 was one for ~8 h): the smallest rung, whole
HOME=/tmp/fakehome python3 tools/ptydrive.py /tmp/p.raw 1500 -- '<url>' auto -- '\[Enter = 1\]' 'c\n' 'type a video ID' '160+140\n'
```

## A Newsmax show page (10.13.26): no sniffer needed

An episode page — `newsmaxtv.com/Shows/<show>/vid/<uuid>` or
`newsmaxtv.com/vod?ooid=<uuid>` — carries no stream in its HTML; the page's
player asks Newsmax's own service, `nmxmam.nmax.tv/vodservice/?id=<uuid>`, which
answers `[{title, source:[{src, locked}]}]`: the title as `Show Name (MM/DD/YY)`,
the src = the master playlist on the VOD CDN. The engine (`nmx_page_hunt`, before
the probe) does the same with a plain fetch — no cookies, no fingerprint, and the
page itself is never loaded (Chrome sometimes cannot open it at all:
`ERR_HTTP2_PROTOCOL_ERROR`; the link in the address bar is enough).

- `✓ the show page names its stream — Carl Higbie Frontline (10/08/26)`; SOURCE
  shows that title; log `newsmax page: <page> -> <master>`.
- the title names the file when every word of a naming-menu row (`NMX_SHOWS` +
  the learned list) appears in it: `✓ smart name: HIGBIE 10.8.26 [NMX]  (the page
  says: …)` — the naming window's own form, so the window is NOT opened. No row
  matches (`Wake Up America`) → the window opens as before, with
  `-> the page says: <title>` under the default name and the air date from the
  title as its Enter date.
- an empty answer from the service → `Newsmax's own service lists no stream for
  this page — the episode may not be posted yet`; `locked: true` (the site's
  Newsmax+ badge on the newest episodes for their first days) → one note,
  `the site shows this episode as Newsmax+ — the stream answers anyway`, and the
  rip goes on (proven 10.13: master, rendition and segments all answer 200 to
  anyone); the service unreachable → the page is probed as before.

**A SHOW page, no episode id** (`newsmaxtv.com/Shows/<slug>`, `nmx_show_hunt`):
the engine reads the page's own listing call (`/api/v1/_24iService/GetPlaylist?
category_ids=<id>`, the id sits in the page; the answer is JSON inside an XML
`<string>`) and lists the newest nine episodes. PICKER/STUDIO: a framed
`WHICH EPISODE?` list, `1)` = newest with the site's `N+` badge where it has one,
`number [Enter = 1] ›`. BEST/AUTO and unattended runs take the newest:
`✓ newest episode: Carl Higbie Frontline (10/13/26)`. The pick becomes the
episode page and the rest is the episode-page path above (the "names its stream"
line then goes to the log only — said once). This is the door that needs no
browser at all: bookmark the five show pages, copy a show link, rip.

Hand test: an episode link at `480 auto` — the three lines above and a file
named `<ROW> <m.d.yy> [NMX].mp4` with no naming window. `slipmat smoke` 3a6
unit-tests the id, date and row matchers.

## The Newsmax door waits for the shows not posted yet (11.4.26)

The four daily shows drop over the evening; the early ones are up while the late
ones still show yesterday's episode. `slipmat newsmax h b b b` rips what is there
and, for every show whose newest episode is not dated today, keeps watching: the
site is read again every 10 min (NMX_WAIT_EVERY seconds overrides, for a test),
and the moment a show's newest episode carries today's date it is ripped with its
own answer (its window opens, or it runs in place under `--here`). The watch ends
when every show is in or after NMX_WAIT_H hours (3; `--wait 2` on the line, `now`
or `--wait 0` = no watch), and the closing line says how many were picked up and
which never posted. `x` ends the watch early (asked once); rips already running
are not touched. A running rip counts as taken: its reservation in the
`_in progress` folder (`<name>.mp4.claim`) reads as "ripping now in its own
window", so a second run of the door never opens a second window on the same show.
Proven 11.4.26 19:17 live, non-tty, `NMX_WAIT_EVERY=5 --wait 0.003`: Higbie and
Schmitt (ripping) left alone, Kelly and Finnerty (11.3 newest) watched, two polls,
"never posted in the 0.003 h". Smoke 3f parses `--wait`.

## The Newsmax door asks which day (11.6.26, 4.28)

The door's first question is the day, not the quality: `t` today's · `y`
yesterday's (the last episode before today's, so Friday's on a Monday) · `b` both
· `c` custom (how many days back, then every episode of today and those days,
numbered, picked by hand: `2h 3 7q`, `2-5` for a span, `all` / `all h`, a number
alone = that show's usual, Enter = every one not in the folder). Each show's
episode list is read once (`show_list`: every episode the page lists, with its
date and how many days back it is, plus the show's rhythm); the stream is asked
for when a rip starts. The overview above the question says, per show, today's
state (posted · not posted yet with the usual time) and the one before it, with
"in the folder" / "ripping now" where that holds. A day with nothing left to rip
says so and asks the day again (a tty) instead of ending. On the line the day word
leads (`yesterday h b` · `both` · `back 5 2h 3` · `c` = back 7; `b h q q` is no
day word, so the old picks lines still work); no day word in a non-tty run = today.
Proven 11.6.26 20:50–21:05 against a fake engine and a fake output folder (one
11.5 file, one 11.6 reservation): `list`, `yesterday` (3 ripped, 1 skipped),
`today h` (Kelly 11.6 not up at 8:53pm → watched), `both b h --wait 0.003` (5
ripped, 2 there, Kelly never posted), `back 3 2h 5 8-9q now`, `today now` (Kelly
"outside the watch, left for later"); through a pty: Enter·Enter, `c`·`1`·`1h 3`,
`y`·Enter, and the all-in-the-folder re-ask (`Enter` → "today's episodes are all in
the folder" → `y` → `q`). Smoke 3e: `--parse-line` (`--parse-day` until 4.34), `--custom-picks`.

## The Newsmax door knows each show's day (11.6.26)

"Today's episode" is read from each show's own episode list, not the calendar
alone: the weekdays it posts and the median time of day it goes up (the episodes
posted on their own date, the last 20). A show is watched only when today is one
of its days and its usual time, with half an hour of room, falls inside the watch.
Before that — the morning after, a weekend, a day it is off — the newest episode
is the current one: ripped if it is not in the folder, nothing watched. The 4.26
door on the morning of 11.6 called all four 11.5 shows "not posted yet" and
would have watched three hours for episodes due that evening. The four shows'
lists (11.6): Mon–Fri, Higbie about 5:02pm, Schmitt 6:02pm, Finnerty 7:05pm,
Kelly 7:58pm (Pacific). A late show's line names its usual time. Proven 11.6.26
13:37 `slipmat newsmax list`: all four read 11.5.26 as current, none watched.
Smoke 3e: Friday 1:36pm = no watch, 3pm = the 5pm show watched, a Saturday = none,
`--wait 0` = none, an unknown rhythm = every day at noon.

## The Newsmax command reads its whole line first (11.12.26, 4.34)

What broke: `slipmat newsmax --help`, run with nobody at the keyboard, opened a rip
window for every show. No word on the line was ever refused — anything that was not a
day word fell through to the answers, and an answer the command did not know read as
`best`. A typo (`lsit`, `yesterdy`), a flag from another tool, or `--here` anywhere but
first did the same.

The rule now: `parse_line` reads every word before a show page is fetched. Words may
come in any order and any case: a day (`today` `t` · `yesterday` `y` · `both` ·
`back N` / `custom N` / `c`), `list`, `help` (`-h`, `--help`), `--here`, `--wait N`
(hours, 0–24; a number is required), `now`, `again`, and the answers. Everything else is
an error: one sentence naming the word, `nothing was read and nothing was started`,
exit 2. The answers are checked against the day's grammar — after `back N` they are row
numbers (`2h 3 7q`, `2-5`, `2:480`, `all`, `all h`), otherwise `b h q s u` or a height —
and against the rows once the lists are read: more answers than rows is refused, a short
line leaves the rest at each show's usual. At a question a wrong answer is named and the
question asked again; `x` (and a closed keyboard) leaves with `nothing started`.

Also in 4.34:

- **1080 = high.** A plain `1080 auto` rip of this source is brought down to 720 by the
  engine's defect rule, so the answer `1080` promised a size it did not deliver; it now
  reads as `h` (native at `NMX_HIGH_Q`). The single-digit "row from the sizes list"
  answers are gone: no screen ever showed that list.
- **A window that did not open is said.** `osascript`'s result is read; a refusal is a
  red line per show, named again on the closing line, exit 1. Under `--here` a rip the
  engine ends non-zero is `did not finish`. A show whose list the site did not give
  (asked twice, two seconds apart) is named on the closing line too.
- **Two runs a moment apart.** The engine reserves a name only after its probe; a second
  run inside that gap used to open a second window per show. Each started episode now
  leaves an empty mark in `~/.slipmat/nmx-started/` for 3 minutes (created with
  noclobber, so only one run wins); the other run says `started a moment ago`. The
  folder is read once more right before each rip.
- **A reservation whose engine is gone.** A killed rip leaves `<name>.mp4.claim` behind
  and the show read as "ripping now" until the engine's two-day sweep. The command looks
  the reservation up in the scratch folders' `claims` ledgers: when one names it and
  that engine's pid is gone, the empty reservation is removed and said (`a rip that
  ended without finishing had left this name reserved; cleared`). A reservation no
  ledger names stands.
- **`again`** rips an episode that is already in the folder (the morning's quick copy,
  re-ripped at best in the evening); the engine names the second copy by its size. At
  the day question it rides on the answer: `t again`.
- **`back N` with nobody there** lists the rows and starts nothing; `back 7 all` or row
  picks start them. A span that reaches past what the site lists says how far the lists
  go (each show lists its last ten episodes).
- **The watch.** Enter no longer reads the site at once (a held key was a tight loop on
  the site): the site is read on the clock only. The watch looks for the day it began
  on, so one that runs past midnight still finds that day's episode. Keys banged after
  the stop are swallowed. `x` is offered only when there is a keyboard.
- The shows' lists are read side by side; a date the site garbles skips that entry
  instead of the show; a usual in `NMX_DAILY` that is no answer is said and read as best;
  `set -f`, so no word on the line is ever a file pattern.

Proven 11.12.26 23:15–23:25 against a stand-in engine, a stand-in `osascript` and
written episode lists (`NMX_LISTS_DIR`): the ten refusals; `today` in windows and
`--here`; per-row answers; a watch that picks a show up when its list gains today's
episode, one that runs out, and through a pty one where three Enters did not move the
9-second clock and `x`·`k`·`x`·`xxxxx` ended it; `again`; the three reservation cases
(owner gone → cleared, owner alive → left alone, no ledger → stands); `yesterday`,
`both h b`, `back 3` (lists only), `back 3 all`, `back 3 2h 3:480 5-6q`, `back 30 1`;
a config with a bad usual, a bad slug and a show that does not answer (exit 1); every
question through a pty with wrong answers first. Live, read-only: `slipmat newsmax list`
read the four shows and saw the four rips then running as "ripping now in its own
window". Smoke 3e (`--parse-line`, the answers) and 3e2 (the command end to end,
offline: `--help` and an unknown word start nothing).

## A YouTube link that names one video and its playlist (11.4.26)

`watch?v=ID&list=…&index=N` is what YouTube hands out when a video is opened from
inside a playlist. Left alone, `yt-dlp -J` dumps the whole playlist: every entry
is read (a minute on a 19-entry list), one upcoming entry can fail the dump, and
the lead-clip rescue then ripped the list's FIRST video, not the one the link
names, as its only combined file (itag 18, 360p) over a bare googlevideo URL that
YouTube throttles once the page's challenge answer is gone (0.1 MB/s, 11.4.26 log).

The engine (`yt_one_video`, before any probe) cuts such a link to the one video it
names: `watch?v=ID` (a `t=` start time rides along), said once as "that link names
one video inside a playlist — ripping that video, not the list". A bare playlist
link (no `v=`) is left alone — it names the list and rips its lead video as before.
Under it, the playlist rescue (`plrescue`) picks the entry whose id the link names
when a `v=` survives, and hands a YouTube entry back as its watch page, never a
bare file, so yt-dlp sees the whole size ladder and the fast lane. Smoke 3i proves
the cut on four link shapes and both rescue answers on a two-entry fixture.

## A rendition playlist from a sniffer (10.13.26, Newsmax)

A network sniffer hands over whatever the player fetched last. For an HLS
stream that is often ONE rendition — Newsmax's `…-video=2359677.m3u8` (video
only) or `…-audio_eng=128000.m3u8` (audio only) — not the master playlist that
lists every quality. A lone rendition dumps as one format with no codec, so the
photo-post gate used to answer `no video at this link — it looks like a
photo/text post`, four times in a row on 10.13.

What the engine does (`hls_master_hunt`, before the probe, any `.m3u8` link):
read the playlist once (small, public, no cookies); a master (`#EXT-X-STREAM-INF`)
passes through untouched; a media playlist tries the siblings in order — the
item id (`…/item=X/version=V/X.m3u8`, Unified Streaming's naming, which is
Newsmax's), then `playlist.m3u8`, `master.m3u8`, `index.m3u8` — and the first
master wins:
`✓ that link is the video-only rendition of the stream (what the sniffer caught) — using the master playlist beside it, which lists every quality`
(log: `master playlist: <given> -> <master>`). No master found → the rendition
rips as given; an audio-only one then dies honestly with what to copy instead.
A `.m3u8` link is never called a photo post.

Hand test: either Newsmax rendition link at `480 best` → the line above, SOURCE
`Newsmax broadcast`, the normal NMX name. `slipmat smoke` 3a5 unit-tests the
candidate list (item id first; `playlist.m3u8` skips itself → `master.m3u8`).

## Bot-walled pages (10.13.26): the browser ladder

Some sites sit behind a bot challenge that refuses yt-dlp's plain fetch with a
403 before the page is even read. Rumble is one since 8.10.26; on 10.13.26 the
challenge also started refusing a single browser fingerprint INTERMITTENTLY.
Measured that day on Rumble's embed endpoint (`--impersonate <x> -J`, 21 probes):
Chrome passed 7 of 7, Firefox 5 of 8 (and 0 of 5 in the day's real run logs),
Safari 0 of 3; sending the Firefox cookies made no difference either way.

What the engine does (`IMP_LADDER`, `imp_probe`, `imp_rotate`):

- the plain probe fails → `site refused the probe — retrying as a real browser …`,
  then one probe per rung — chrome, firefox, safari — and the first rung that
  reads the page is kept: `✓ unlocked via browser impersonation (chrome)`.
  It rides every later yt-dlp call (`$IMPARGS`). All three refused → one line
  `no browser fingerprint unlocked it (chrome, firefox, safari)` and the usual
  embed hunt / honest death follow.
- the download re-reads the page with that fingerprint and can be refused again
  seconds later. When an attempt's stderr carries the PAGE-read 403 (`Unable to
  download webpage` / `Unable to download JSON metadata` / `Cloudflare anti-bot`,
  each with `HTTP Error 403`) the engine says
  `! the site refused the page again at the download (chrome) — retrying as firefox …`
  and runs the same attempt again. A segment error (a 503 on a fragment, `unable
  to download video data`) never rotates — those belong to the CDN retry ladder.
- the fingerprint that reads the page can be one the site's VIDEO server will
  not talk to (11.12.26, Rumble: five rips in a row died in under 20 seconds with
  `curl: (56) Connection closed abruptly`; on one rendition playlist chrome and
  firefox had the connection closed before a byte, safari and a plain fetch were
  served). When an attempt under a fingerprint ends on a curl-level close (56,
  35 or 92) with nothing downloaded (under 1 MB in the scratch) the engine says
  `! their video server hung up on chrome before a byte landed — retrying as firefox …`
  and runs the same attempt again on the same rung. A close with a partial
  already in hand is CDN weather and never rotates (`imp_hungup`). A ladder
  that ends there dies by name (`closed the connection on every browser
  fingerprint tried`), not as a transient CDN wall.
- at most three fingerprints per run, each tried once; a rescue that proved a
  rung (C-SPAN, the manifest swap) keeps firefox there.
- `SLIPMAT_BROWSERS="chrome firefox safari"` in the config reorders the ladder.
  Measure before changing it: a loop of `yt-dlp --impersonate <x> -J <page>` per
  rung, a handful each, no cookies needed. The same key is the forced test of the
  download-stage rotation: `SLIPMAT_BROWSERS="firefox safari chrome"` on a Rumble
  page makes firefox unlock the probe some of the time and get refused at the
  download's re-read some of the time — the `retrying as …` line then shows.

Hand test (network): a Rumble page at the lowest rung, e.g.
`slipmat 'https://rumble.com/v7grjhc-….html' 360` — expect the two lines above
and a normal receipt. The run log carries `impersonation: <rung> refused` for
every rung that failed. `slipmat smoke` 3a4 asserts the ladder's shape and runs
`imp_refused` on a fake page-read 403 (must match) and a fake segment 403 (must
not). 3a4b runs `imp_hungup` on a fake curl close under a fingerprint with an
empty scratch (must match), and on a plain fetch, a segment 503 and a close with
2 MB in hand (must not).

## A cbs.com video page (11.12.26): read from the page's own player data

yt-dlp's CBS extractor asks an endpoint that answers empty on every fingerprint
(`Failed to parse XML … no element found`), so the probe and the browser ladder
both come back with nothing. The page itself carries what its player needs, in
`player.apiMetadata`: the manifest (`streamingUrl`), the title, the content id,
the air date and the length. The page hunt reads that and the rip continues on
the manifest:

- `✓ the page embeds a video (CBS clip) — ripping that`, then a normal receipt
  named `TITLE [content id] - air date`, with `Duration` in the SOURCE box and a
  `got: … of …` line in the log (the length is the page's; a bare manifest's
  dump has none).
- only a page that says `"isProtected":false` is taken. A protected video plays
  only in the site's player; the run ends on the usual `nothing could be read
  from this page` sentence.
- the size is whatever the manifest lists (576p on the clip this was built on).

Hand test (network): `slipmat 'https://www.cbs.com/shows/video/<content id>/' best`
on a free clip. `slipmat smoke` 3j runs the page reader offline on a saved page
(`SLIPMAT_HUNT_PAGE=<file>` stands in for the fetch): a free page gives the five
values, a protected page and another site's address give nothing.

## A page with no stream address (11.12.26, 4.35): the reader follows its player

A show's home page copied from the address bar: no extractor, the browser ladder
refused, and nothing in the page to find, because the page only loads a player
script. The chain there: page → its `Watch the Show` link → a script
(`embed-player.js`) → a player address that script spells from two constants in a
template string (`https://player.zype.com/embed/${LIVE_VIDEO_ID}.js?api_key=${LIVE_API_KEY}`)
→ that answer names the channel's master playlist. Step 6 of the page reader
(`embed_hunt`) walks it:

- from each text it reads: a playlist address (plain or JSON-escaped), the
  frames and player-named scripts it loads, and the player addresses in its
  strings once `${NAME}` is filled in from the text's own `const NAME = '…'`;
- breadth first, three steps deep, 12 fetches, 25 seconds; ad, consent and
  analytics hosts are never fetched;
- a playlist is taken only when it answers `#EXTM3U` and names no DRM key system;
- when the page's own player leads nowhere, up to three same-site links that say
  watch or live get one step (never one that says listen, radio, podcast or audio);
- cbs.com is left out (a page its own reader did not take is a protected one).

The screen: `✓ the page embeds a video (the stream its player loads) — ripping that`
(with `, found on /watch-the-show` when a link was followed). A bare playlist
found this way, or by the older `manifest in page` step, is named by the page's
title with no bracket (`master [master]` and a hex channel id were the names
before); a title under 12 characters gets the site beside it (`Watch - wjla.com`).
A playlist a dedicated extractor reads keeps that extractor's title and id.

Proofs (11.12.26, ptydrive, fake HOME with `SLIPMAT_PYTHON` set to the python
that has curl_cffi, `360 auto`, x x):

```
# the copied home page, tracking words and all: the stream its player loads,
# the piece-address retry of 4.33, 0:41 in the file, named by the page's title
HOME=$H PTY_COLS=104 python3 tools/ptydrive.py /tmp/f1.raw 120 -- '<show home page>' 360 auto -- KEY@45:x KEY@2:x
# station live pages: two recorded live by way of "manifest in page"
# (0:46 and 0:51), one page's newest newscast downloaded as a replay
```

The reader alone on twelve station and channel live pages: eight gave a playlist
in the page as written, one more by following its player. Three gave nothing: two owner
groups whose players sign each request with a key, and one site that refuses the
page itself. Each of those needs a reader of its own. One site's page is read by
yt-dlp's generic extractor before the reader gets a turn and gives a one-minute
promo clip instead of the live stream.

`slipmat smoke` 3j2 runs the chain offline (`SLIPMAT_HUNT_MAP=<json of address →
saved file>` stands in for every fetch): home page, watch page, a DRM playlist,
a broken chain, and the title of a raw playlist.

## The keys (10.6.26): one key language — x stops, ↓ steps down, Ctrl-C is the exit

Every key a user may press is printed before it can be pressed (a rail block
under the stage header) and means ONE thing, the same on every screen.
`tools/keys.py` reads the terminal in cbreak mode with echo off and restores it
(input flushed) on every exit path.

- `x` = stop, asked once. The first `x` prints "stop the download? / stop the
  re-encode? / stop the capture? — x again = stop · any other key = keep going"
  and waits 5 s; a second `x` stops. Any other key, or 5 s of nothing, prints
  "keeps going". After the stop every further key is swallowed until the
  engine has written its words (a third, fourth, fifth `x` lands nowhere).
  - download → `download canceled (x) — nothing kept.`, exit 130
  - re-encode → `re-encode canceled (x) — nothing to worry about.`, the
    original stays, exit 130
  - live → the exact first-Ctrl-C path in `live-rewind.py` (seal one playable
    mp4, keys disarmed until the receipt); the log says `stopped by x`.
- `↓` = step down one rung, on a download that has a rung below (the rail
  names it). `key.next` (written before every attempt while a ladder exists) is
  the rung it would take; empty = the floor ("nothing lower", nothing
  interrupted); missing = no ladder on this screen, the key does nothing.
- Ctrl-C is not a slipmat key and is never printed: the terminal's own
  emergency exit. It still does what it always did (download: cancel outright;
  re-encode: calm cancel; live: stop at once and seal). Logs name it.

Mechanism: `keys_start <download|re-encode> [rung]` prints the rail and starts
`keys.py watch <engine pid> <scratch>` as a background job; the second `x`
leaves `key.x`, a `↓` leaves `key.down`, and either sends the engine's yt-dlp
(child or grandchild) or ffmpeg (direct child) the SIGINT a Ctrl-C would. `by_hand`
+ the flags tell the keys apart. `keys_stop` runs right after the download /
encode and inside every cancel path, AFTER the words — the reader must never be
alive across a question, or it would eat the answer. Live keeps its in-process
thread (`live_thread`).

Proofs (10.5.26 ~22:40; `KEY@secs:text` types keys into the pty, delays are
CUMULATIVE; the harness resets SIGINT to default in the child — a harness run as
a background job of a non-interactive shell would otherwise hand yt-dlp an
ignored SIGINT and the keys would look dead):

```
# 1. the ladder on Mux's public multi-rung HLS sample: x · y · ↓ · x x · xxx (swallowed)
HOME=$H PTY_COLS=104 python3 tools/ptydrive.py /tmp/r.raw 150 -- \
  'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8' max best -- 'while it downloads' '' 'KEY@2:x' 'KEY@1:y' 'KEY@2:\x1b[B' 'KEY@4:x' 'KEY@0.2:x' 'KEY@0.5:xxx'
#   → rail "x stop — it asks once · ↓ too slow? step down to 720p" · "stop the download? x again = stop · any other key = keep going"
#     · "keeps going" · "↓ at 1080p — stepping down to 720p (↓ again = 480p)" · the question · "download canceled (x) — nothing kept." · exit 130
# 2. a download with no ladder (a direct mp4 — the same screen PICKER/STUDIO custom picks get): the rail has x only
HOME=$H PTY_COLS=104 python3 tools/ptydrive.py /tmp/p.raw 150 -- \
  'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_30MB.mp4' max best -- 'while it downloads' '' 'KEY@0.3:x' 'KEY@0.2:x' 'KEY@0.3:xx'
#   → "download canceled (x) — nothing kept."
# 3. a re-encode (offline fixture; make it long enough to press keys into: testsrc2=duration=240)
SLIPMAT_LOCAL_MKV=/tmp/fix.mkv HOME=$H PTY_COLS=104 python3 tools/ptydrive.py /tmp/e.raw 150 -- \
  'https://example.test/x' max auto -- 'while it re-encodes' '' 'KEY@1.5:x' 'KEY@1:y' 'KEY@1.5:x' 'KEY@0.2:x' 'KEY@0.5:xxx'
#   → "stop the re-encode? …" · "keeps going" · "re-encode canceled (x) — nothing to worry about." · exit 130
# 4. a live stream: x (question) · y (REC resumes) · x x (stop) · xxx and a late x (swallowed)
HOME=$H PTY_COLS=104 python3 tools/ptydrive.py /tmp/k.raw 150 -- '<live url>' max best -- \
  'capture start' '\n' 'while it records' '' 'KEY@15:x' 'KEY@2:y' 'KEY@8:x' 'KEY@0.2:x' 'KEY@0.3:xxx' 'KEY@3:x'
#   → one h264/aac mp4, "captured 0:40 of video", log "stopped by x", exit 0; pgrep keys.py = nothing left
```
Real screens from 10.5.26: `NOTES/2026-10-05-asks-renders/keys-x-*.raw` in the
private notebook (`bash show-keys-x.sh` there renders all four).


## The day's Newsmax shows (11.2.26): `slipmat newsmax`

`tools/newsmax-today.sh` reads `NMX_DAILY` from `~/.slipmat/config` (pipe-separated
`slug=usual answer`, the slug from `newsmaxtv.com/Shows/<slug>`), reads each show the
way the engine's show door does (the show page's listing call → newest episode →
Newsmax's own service → title, master playlist) and prints one row per show: the
name the engine will write (`<ROW> <m.d.yy> [NMX]`) and its usual answer, or
`already in the folder` when that file exists. Then ONE question — `How do you want
them?` — answered for every show at once or one per show in order: `b` best (720p CFR
re-encode, the engine's `best`), `h` high (native 1080p CFR re-encode at `NMX_HIGH_Q`,
default 45 — the engine's `best` under `SLIPMAT_KEEP_NATIVE=1 SLIPMAT_Q=<q>`; `h55` = at
that dial), `q` quick (`480 auto`, a direct copy), `s` small (`360 auto`), or a height
(since 4.34 `1080` reads as high and the row-number answers are gone). Enter = each show's usual. Then a Terminal window per show
(the launcher's kind: `SLIPMAT_WINDOW=1`, closes itself after a finished rip; `x`
stops, `↓` steps a slow download down); `--here` or `NMX_WINDOWS=0` runs them in the
current window one after another. `slipmat newsmax h b q q` skips the question.
`slipmat smoke` 3e asserts the answers line and each answer's engine words
(pure hooks `--parse-picks`, `--answer-cmd`). The engine's
`SLIPMAT_KEEP_NATIVE=1` keeps a defective >720 source at its native size in the
no-questions modes (the receipt says `kept at 1080p (native asked for) · q50`).
Live proof 11.2.26 20:34: `slipmat newsmax h b b b` read the four shows, skipped the
one already in the folder and opened three windows that ripped side by side.

## The silent-file rule (11.2.26)

A file that lands with no audio stream is told apart, once on screen and again on
the receipt's `audio` line: `silent by nature — the source has no audio track`
(the dump lists none) versus `the source lists an audio track, but none could be
fetched` (the dump claims audio, the pick landed silent, the re-fetch landed silent,
and the audio-only rescue — `-f ba` fetched on its own and paired in with ffmpeg,
`audio_only_rescue` — found nothing either). The rescue sits on both download paths
(fast path and mkv scratch) and runs only after the existing one re-fetch. `slipmat
smoke` 3f runs `silent_verdict` on a 1 s silent mp4 against a no-audio dump and an
audio-claiming dump and asserts both sentences, the receipt line, and the rescue
call on both paths. Two cosmetic rulings landed with it: the source note never says
`· ?` when the dump carries no codec, and a reel whose dump lists only non-QuickTime
codecs says it once, at the landing (`only vp9 is offered — converting to HEVC`),
the first line now log-only.

## The high dial, measured (11.2.26): `slipmat compare` on an hour of 1080 broadcast

The 1080 h264 source (2.07 GB, 25% stutter → the CFR re-encode runs) scored at
q40 45 50 55 60, six 10 s windows: q40 ≈1.36 GB · q45 ≈1.70 GB (+25%, +1.3 VMAF =
0.21 JND) · q50 ≈2.14 GB (+58%, at the source size) · q55 ≈3.00 GB (+121%, 0.56 JND)
· q60 ≈3.71 GB (+174%, 0.63 JND). Every step above q40 stays under one
just-noticeable difference in normal viewing; q50 lands at the source's own size
and q55–q60 are 1.5–1.8× the source. So `high` renders at q45: the last dial under
the source size, the sharpness of 1080 native with none of the bloat. The dial is
`NMX_HIGH_Q`; `h55` on the answer line overrides it for one show. The ledger row is
in `~/.slipmat/logs/compare-ledger.tsv`; the side-by-side clip (q40 | source | q60,
with damage maps) sits in `~/.slipmat/compare/`.

## The title hook, widened (11.3.26)

`~/.slipmat/title-hook` now runs for every source except social clips (X, TikTok,
Instagram, Threads, Truth Social, Facebook — the handle is their identity) and gets
three arguments: the title, the channel or handle, and the source tag (`WH`, `CSPAN`
or the platform tag). It answers one line: the name, optionally a tab and the
event's own date (`M.D.YY`, which outranks the upload date), optionally a tab and the
bracket tag to write (`-` = none; empty = the source's own `[WH]`/`[CSPAN]`). The
engine's `smart_title` is the one reader; the VOD name and the live-capture name
both use it (a smart-named live capture keeps its `[L- date - time]` stamp). A
second copy of one video at another size is suffixed `(720)` rather than `(2)`
(`uniquify` takes the picked short side; the same size still bumps to `(2)`), and
`place_final` corrects that suffix to the size that actually landed (a 1080 pick the
defect rule brought to 720 reads `(720)`). Since 4.29 the Newsmax names reach the same rule:
the show-door name passes the pick to `uniquify`, and the naming window's two renames (at the
finish line, and late from the window itself) read the size that landed before they claim a
name (`size_suffix`; smoke 3h2). Own-output recognition reads a smart name
ending in ` - M.D.YY`. `slipmat smoke` 3g runs the engine with a throwaway hook that
answers `SMART NAME<TAB>10.21.26<TAB>-` and expects `SMART NAME - 10.21.26.mp4`; 3h
unit-tests the size suffix and the placement correction. The menu-bar door
`[SLIPMAT VIDEO] NEWSMAX` (`make-shortcuts.sh -n`, launcher mode `newsmax`) opens a
window that asks the one question and closes itself 45 s after the show windows open.

## The way in that worked last time (11.13.26, 4.36)

Two months of run logs: 1,385 runs, 60 refused first reads. One site refused on
36 of 36 runs and then took four more refusals before each download (the video
server hung up on chrome, then firefox; the page refused safari; the playlist
itself, asked as safari, was served). A player host needed its embed page on 586
of 592. The run arrived every time, the long way.

`~/.slipmat/routes` holds one line per site and stage (tab-separated: host, stage,
value, runs in a row, last day):

- `probe`: the fingerprint the page opened to after refusing a plain read. Written
  by the main probe's ladder only. Applied from 2 runs in a row. A plain read that
  answers forgets it; every 25th run reads plain first, quietly.
- `referer`: the NUMBER of the configured embed page that opened a player link.
  Only a page still in `SLIPMAT_EMBED_HOSTS` is ever sent.
- `hlsdl`: `manifest:<fingerprint|plain>`, written when a page download landed only
  after the swap to its playlist. Applied before the first attempt; an attempt that
  lands under 1 MB puts the page route back whole, forgets the line and says
  `this site's usual way in did not answer this time — taking the long way`.

youtube.com and instagram.com are never routed. `SLIPMAT_ROUTES=0` turns it off.
The run log says `route: …` for each one used; the screen says nothing.

Proof (throwaway HOME, a 56-minute replay on the site above, picker row 4 = 360p):
run 1 took all five refusals and landed 360p (before 4.36 a picked row landed as
the top size after the swap: its id is not in the playlist's own list, and the
selector fell to its uncapped tail; `sel_height_led` now puts the picked height
ahead of the fallbacks); run 2 wrote both lines; with the count set to 2 by hand,
run 3 read the page as chrome, asked for the playlist as safari, printed no refusal
and finished in 0:27. Smoke 3m covers the ledger, the skipped hosts and the selector.

## `slipmat review [days]` (11.13.26)

`tools/review.py` reads `~/.slipmat/logs` (30 days by default, `all` for every
day, `--logs DIR`, `--min N`, `--share PCT`, `--json`) and prints three lists: HABITS
(a detour on half or more of a site's runs, sites with five or more runs), OFTEN
(the fifteen most frequent other detours) and FAILED RUNS (a closed window and a
canceled run are counted apart, never as failures). Lines are reduced to shapes:
no address, title or number leaves the logs. Smoke 3p runs it on a built tree.

## The count on the where-to-start question (11.13.26)

BEST and AUTO count down to Enter on a live source. The count used to redraw its
line over a line read: the key just typed was wiped off the screen and kept by the
terminal, so each new try stacked up unseen (four presses of 1 entered `1111`:
1111 minutes back, past the stream's four-hour window). `typed_countdown` reads a
key at a time: the key is drawn and stays, Backspace takes one off, every key
starts the count over, and the count lands on what is typed. Smoke 3k drives it
in a pty. Live: `1` typed and left alone on a 24/7 stream → `the timer landed › 1`
→ `last 5m`, 5:37 in the file.

## A row, and what happens to it next (11.13.26)

Picker answers: `2s` (or `s2`, `2 s`; `s` alone = the top row) hands the rest of
the run to STUDIO after the pick: its box widths, its window size, its questions.
`2 950mb` (also `1g`, `under 1.5gb`, `<900m`; decimal MB) does the same and answers
STUDIO's size question with keep and its recipe question with the size. At the
recipe prompt a size picks the highest dial in 56 … 25 whose estimate is at most
90% of the size (an un-probed table is probed first); the file's own number at the
picked dial moves the dial down before the encode when it is over; a file that
lands over runs once more at a dial sized from its real bytes (4% under); a source
already under the size is kept untouched; no dial that fits is said and the table
asks again. Smoke 3n covers the grammar. Hand proofs: a 100 s 720p noise clip at
9 Mbps with `under 40mb` → q50 landed 60 MB → second pass q35 → 24 MB; a 173 MB
YouTube 720p row with `4 60mb` → `even q25 lands over 60MB here` and the table
again; the same row with `4 200mb` → `already under 200MB`, kept.

## A recording nobody came back for (11.13.26)

`seal_abandoned` runs once per run, before the probe. In `_in progress`: a
`NAME.mp4.part` (or a rewind's `NAME.f<id>.*` halves) not written for 3 minutes,
whose reservation is named by a scratch folder with a dead process id (no scratch
folder: 20 quiet minutes). Streams are copied into `NAME.sealed.mp4`, its length
must reach 98% of the raw file's, it is placed as `NAME.mp4` (or ` (2)`), then the
raw file and the empty reservation go. A lock folder keeps two runs off one
capture; too little free space waits; a failed seal leaves `NAME.unsealable` and
is not tried again. Smoke 5c: a dead capture and a pair of halves are sealed, a
capture whose run is alive is left alone. Real size: a 12.4 GB six-hour raw file
sealed in 20 s to 5:56:24, byte for byte the size of the hand seal.
