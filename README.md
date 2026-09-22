# slipmat

**Copy a link. Click. Get a file that just works on your gear.**

⌘C & hit the menu bar. A URL, or a file in Finder — same move.

- **Video** never stutters in QuickTime. Every rip is verified after
  download; a defective stream gets fixed automatically.
- **Audio** pulls the best stream the source serves → AAC-320 through
  Apple's encoder, artwork squared, real source bitrate in the tags. One
  output, no flags, plays on everything.

Every rip prints a receipt, and every run keeps a log in `~/.slipmat/logs` —
toss a fail log at an AI agent and slipmat becomes self-diagnosing.

## Install

You'll need a Mac and [Homebrew](https://brew.sh). Apple Silicon is the
fast path — slipmat uses Apple's built-in encoders under the hood.

```
brew install ffmpeg yt-dlp
./slipmat hello
```

(Prefer pip? `pip3 install -U "yt-dlp[default,curl-cffi]"` adds the
browser-impersonation extras — just make sure pip's bin dir is on your PATH.)

`slipmat hello` is the whole setup: it asks where video and audio rips should
land (Enter takes the defaults; audio can go straight into your Music
library), checks the toolchain, and **installs the four menu-bar Shortcuts** —
built for your machine, signed locally, pre-pinned to the menu bar; you click
"Add Shortcut" on each. Details and the manual path: `shortcuts/SETUP.md`.

One habit worth keeping: **log in to your video sites (YouTube etc.) in
Firefox and stay logged in.** slipmat borrows Firefox's cookies, so sites
treat it like you — members-only, age-gated and premium-tier streams just
work. (A different browser or none at all: set `COOKIE_BROWSER` /
`USE_COOKIES` in `~/.slipmat/config`.)

`python3` is used for stream selection and artwork; the zoom-crop feature
additionally wants a python with `numpy` + `scipy` (set `SLIPMAT_PYTHON` in
`~/.slipmat/config`). Run `./slipmat doctor` — it checks everything and prints
the exact command for anything missing.

## Use

You *can* trigger slipmat from the command line — but that's not the design.
slipmat lives in your menu bar: **copy a link anywhere, and two clicks later
your content is heading your way.** The dropdown shortcut suite:

| menu bar | it does |
|---|---|
| [SLIPMAT VIDEO] AUTO(BEST) | the best quality your machine can actually play, ripped bulletproof — zero questions asked |
| [SLIPMAT VIDEO] PICKER | see the source's REAL resolutions (1080p, 720p, …), pick one, the rest is automatic |
| [SLIPMAT VIDEO] STUDIO | the picker plus a re-encode concierge — shrink or optimize (sizes/ETAs probed from YOUR file, not guessed), or crop away the dead screen around a small video box. Works without a URL too: ⌘C any bloated file in Finder, click STUDIO |
| [SLIPMAT AUDIO] AUTO(BEST) | copied link → a clean .m4a with real artwork. AAC-320 — the highest AAC rate CDJ hardware accepts, so files are deck-compatible as delivered |

The same doors from the command line:

```
./slipmat hello                      # (re)run setup any time
./slipmat video <url>  best          # best playable quality, no questions
./slipmat video <url>  auto          # pick the stream from a menu
./slipmat video <url>  studio        # menu + re-encode concierge
./slipmat video <file> studio        # local file → the same concierge
./slipmat audio <url>                # AAC-320 m4a, square art, source stamp
./slipmat z-batch -c 50 <folder>     # unattended zoom-crop/re-encode a folder
```

Rips land in `~/Downloads/SLIPMAT` (or wherever you told `hello`); run logs
in `~/.slipmat/logs/<day>/`. `~/.slipmat/config` holds every dial: folders,
browser cookies, quality, naming style, your own embed-page hosts.

## What's under the hood

- Format-aware stream selection: real renditions enumerated, exact ids picked
  by QuickTime-codec preference; the post-download probe is the authority.
- A stutter detector (sorted-PTS gap analysis — container duration lies).
- A re-encode concierge that samples *your* file at the target geometry before
  quoting sizes; estimates have landed within a few percent for months.
- Live streams capture direct to mp4 and finalize cleanly on Ctrl-C.
- Embed rescue: a page that won't probe gets read directly and hunted for its
  embedded video (og:video, JSON-LD, iframes, raw manifests, and several
  site-specific doors).
- Auto-crop: finds the actual video inside a screen recording — the
  picture-in-picture box — and crops to exactly that, one file or a whole
  folder unattended.
