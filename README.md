# slipmat

**Copy a link. Click. Get a file that just works on your gear.**

⌘C & hit the menu bar. A URL, or a file in Finder — same move.

- **Video** never stutters in QuickTime. Every download is verified after
  it lands; a defective stream gets fixed automatically.
- **Audio** downloads become clean .m4a files: AAC-320 through Apple's
  encoder, square album artwork, and the original source quality stamped in
  the **Composer** field (rekordbox can show it as a column, and stores
  rarely fill it, so Album and Comments stay yours). No options to pick —
  every file plays everywhere.
- **Spotify** playlists, albums and tracks get the same treatment, straight
  from Spotify's 320k stream.

Every download prints a receipt, and every run keeps a log in `~/.slipmat/logs` —
toss a fail log at an AI agent and slipmat becomes self-diagnosing.

## Install

A Mac running macOS 12 (Monterey) or later, with [Homebrew](https://brew.sh).
Re-encoding (fixing a stuttering stream, STUDIO's shrink/crop) uses Apple
Silicon's hardware HEVC encoder in constant-quality mode, which Intel Macs
don't offer — on an Intel Mac, plain downloads work but re-encodes will fail.

```
brew install ffmpeg yt-dlp uv
git clone https://github.com/ajdalm/slipmat.git
cd slipmat
./slipmat hello
```

(`uv` is only for Spotify — skip it if you'll never use Spotify.)

The Homebrew version of yt-dlp handles nearly every site. A few stubborn
sites only respond to real web browsers — for those, the pip version of
yt-dlp can impersonate one:

```
pip3 install -U "yt-dlp[default,curl-cffi]"
```

You can skip that until a site actually refuses you. If you do install it,
run `./slipmat doctor` afterwards — it will tell you whether slipmat can
see it.

`./slipmat hello` is a short guided setup. It asks where downloads should
go (pressing Enter accepts the defaults; audio can be sent straight into
your Music library), checks that everything is installed, offers the
Spotify login, and then adds the five slipmat Shortcuts to your menu bar:
macOS pops up an "Add Shortcut" window for each one — press Enter, and the
next one pops up by itself. That's the whole install. If you'd rather set
the Shortcuts up by hand, see `shortcuts/SETUP.md`.

Tip: slipmat uses your **Firefox** cookies. If you're logged in to a site
in Firefox, slipmat can download things that need your account — members-only
videos, age-restricted content, premium streams. To use a different browser
(or no cookies), set `COOKIE_BROWSER` / `USE_COOKIES` in `~/.slipmat/config`.

**Spotify** needs a Spotify Premium account and `uv` (it builds the
Spotify engine's own Python the first time it's needed). `slipmat hello` offers to
log you in to Spotify during setup (or later: `./slipmat spotify --login`);
the login opens in your browser once and is remembered after that.
Stopping mid-playlist is safe — finished tracks are remembered and skipped
next time. The Spotify engine is [mr-rippah](https://github.com/cvdub/mr-rippah)
by cvdub, with upgrades: if Spotify quietly serves a lower tier than 320k,
the track fails loudly instead of landing as a weaker file; rate-limit
pacing and stall recovery; album links; and Music.app delivery.

`python3` is used for stream selection and artwork (with Pillow installed,
artwork letterbox-trimming is sharper; without it, ffmpeg crops); the zoom-crop feature
also needs a python with `numpy` + `scipy` (set `SLIPMAT_PYTHON` in
`~/.slipmat/config`). Run `./slipmat doctor` — it checks everything and prints
the exact command for anything missing.

## Use

You *can* trigger slipmat from the command line — but that's not the design.
slipmat lives in your menu bar: **copy a link anywhere, and two clicks later
your content is heading your way.** Click the Shortcuts icon (two stacked,
tilted squares, top right of your screen) and pick:

| menu bar | it does |
|---|---|
| [SLIPMAT VIDEO] AUTO(BEST) | the best quality your machine can actually play, ripped bulletproof — zero questions asked |
| [SLIPMAT VIDEO] PICKER | see the source's REAL resolutions (1080p, 720p, …), pick one, the rest is automatic |
| [SLIPMAT VIDEO] STUDIO | the picker plus a re-encode concierge — shrink or optimize (sizes/ETAs probed from YOUR file, not guessed), or crop away the dead screen around a small video box. Works without a URL too: ⌘C any bloated file in Finder, click STUDIO |
| [SLIPMAT WEBAUDIO] | Rips YouTube, SoundCloud, etc. → a clean .m4a with real artwork. AAC-320 — the highest AAC rate CDJ hardware accepts, so files are deck-compatible as delivered |
| [SLIPMAT SPOTIFY] | Rips a Spotify playlist, album or track URL → the same deck-ready .m4a files |

The same tools, from the command line:

```
./slipmat hello                      # (re)run setup any time
./slipmat video <url>  best          # best playable quality, no questions
./slipmat video <url>  auto          # pick the stream from a menu
./slipmat video <url>  studio        # menu + re-encode concierge
./slipmat video <file> studio        # local file → the same concierge
./slipmat audio <url>                # AAC-320 m4a, square art, source stamp
./slipmat spotify <url>              # a Spotify playlist, album or track URL
./slipmat spotify --login            # log in to Spotify now (browser, once)
./slipmat z-batch -c 50 <folder>     # unattended zoom-crop/re-encode a folder
```

Downloads land in `~/Downloads/SLIPMAT` (or wherever you told `hello`); run logs
in `~/.slipmat/logs/<day>/`. `~/.slipmat/config` holds every dial: folders,
browser cookies, quality, naming style, your own embed-page hosts.

## What's under the hood

- Careful stream selection: slipmat lists the streams a source actually
  serves and picks by QuickTime compatibility — then verifies the downloaded
  file itself instead of trusting the site's metadata.
- A stutter detector that checks real frame timestamps (container metadata
  often reports a broken stream as fine).
- A re-encode concierge that samples *your* file at the target size before
  quoting numbers; estimates are typically within a few percent.
- Live streams record straight to mp4; press Ctrl-C to stop, and the file
  is finalized and playable.
- Embed rescue: when a page's video can't be reached the normal way,
  slipmat reads the page itself and finds the embedded video (og:video,
  JSON-LD, iframes, raw manifests, and several site-specific handlers).
- Auto-crop: finds the actual video inside a screen recording — the
  picture-in-picture box — and crops to exactly that, one file or a whole
  folder unattended.
