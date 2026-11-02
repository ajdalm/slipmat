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
(`ask_live_start`); the words `from-start` / `last-2h` / `last-90m` on the
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
merged in the scratch instead of fetched again.

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
not).

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

