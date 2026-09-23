# The dropdown shortcut suite — two clicks on a copied link

This is the way slipmat is meant to be used: copy a link anywhere (or select
files in Finder), click a Shortcut in your menu bar, and your content is
heading your way. The suite:

| Shortcut | what a click does |
|---|---|
| **[SLIPMAT VIDEO] AUTO(BEST)** | the best quality your machine can actually play, ripped bulletproof — zero questions asked |
| **[SLIPMAT VIDEO] PICKER** | the source's REAL resolutions (1080p, 720p, …) as a numbered menu — pick one, the rest is automatic |
| **[SLIPMAT VIDEO] STUDIO** | the picker plus a re-encode concierge: shrink or optimize, or crop away the dead screen around a small video box. Works without a URL too — ⌘C any bloated *file* in Finder, click STUDIO |
| **[SLIPMAT AUDIO] AUTO(BEST)** | copied URL → a clean .m4a with square artwork. AAC-320 — the highest AAC rate CDJ hardware accepts, so files are deck-compatible as delivered |
| **[SLIPMAT AUDIO] SPOTIFY** | a copied Spotify track, album or playlist link → the same deck-ready .m4a files. Needs Spotify Premium (first rip opens Spotify's login page once) and `brew install uv` |

## The automatic way (recommended)

```
./slipmat hello
```

The setup session builds all five Shortcuts **for your machine**, signed
locally, pre-pinned to the menu bar, and opens them one at a time — you click
**"Add Shortcut"** on each (Apple requires that one human click; it's the
only manual part). Already ran `hello` and skipped this step? Just run the
builder alone:

```
./shortcuts/make-shortcuts.sh && open ~/.slipmat/shortcuts/*.shortcut
```

Two one-time things macOS will ask:

- On the **first click** of each Shortcut, macOS asks permission for it to run
  scripts / control Terminal. Allow them — that's
  the standard handshake for any Shortcut that does real work.
- The Shortcuts icon appears in the menu bar on its own once the sidebar's
  **"Menu Bar"** folder holds a shortcut (that folder *is* the dropdown).
  A shortcut missing from it? Drag its card onto the folder, or open its
  ⓘ panel → ✓ **"Pin in Menu Bar"**. No "Menu Bar" folder listed at all?
  Shortcuts → **Settings → Sidebar → tick "Menu Bar"**.

Signing requires the Mac to be signed into iCloud (that's Apple's rule for
importable Shortcut files, not ours). If signing fails, use the manual way —
it's two minutes.

## The manual way (five one-line Shortcuts)

For each row: open the **Shortcuts** app → **＋** new Shortcut → add a single
**"Run Shell Script"** action → paste the line → name the Shortcut exactly as
shown → open its ⓘ panel → check **"Pin in Menu Bar"**.

Replace `REPO` in every line with your clone's absolute path (run `pwd`
inside the repo to get it).

**[SLIPMAT VIDEO] AUTO(BEST)**
```
osascript "REPO/shortcuts/launch.applescript" "REPO" best
```

**[SLIPMAT VIDEO] PICKER**
```
osascript "REPO/shortcuts/launch.applescript" "REPO" picker
```

**[SLIPMAT VIDEO] STUDIO**
```
osascript "REPO/shortcuts/launch.applescript" "REPO" studio
```

**[SLIPMAT AUDIO] AUTO(BEST)**
```
osascript "REPO/shortcuts/launch.applescript" "REPO" audio
```

**[SLIPMAT AUDIO] SPOTIFY**
```
osascript "REPO/shortcuts/launch.applescript" "REPO" spotify
```

All five delegate to one on-disk launcher (`shortcuts/launch.applescript`),
so a `git pull` updates every Shortcut's behavior without touching the
Shortcuts app again. If a Shortcut ever behaves differently from running
slipmat in the terminal, it's usually a hand-built Shortcut with an old
command pasted inline — keep Shortcuts as one-line delegators.
