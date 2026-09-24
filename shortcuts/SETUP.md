# The dropdown shortcut suite — two clicks on a copied link

This is the way slipmat is meant to be used: copy a link anywhere (or ⌘C a
file in Finder for STUDIO), click a Shortcut in your menu bar, and your content is
heading your way. The suite:

| Shortcut | what a click does |
|---|---|
| **[SLIPMAT VIDEO] AUTO(BEST)** | the best quality your machine can actually play, ripped bulletproof — zero questions asked |
| **[SLIPMAT VIDEO] PICKER** | the source's REAL resolutions (1080p, 720p, …) as a numbered menu — pick one, the rest is automatic |
| **[SLIPMAT VIDEO] STUDIO** | the picker plus a re-encode concierge: shrink or optimize, or crop away the dead screen around a small video box. Works without a URL too — ⌘C any bloated *file* in Finder, click STUDIO |
| **[SLIPMAT WEBAUDIO]** | Rips YouTube, SoundCloud, etc. → a clean .m4a with square artwork. AAC-320 — the highest AAC rate CDJ hardware accepts, so files are deck-compatible as delivered |
| **[SLIPMAT SPOTIFY]** | Rips a Spotify playlist, album or track URL → the same deck-ready .m4a files. Needs Spotify Premium and `brew install uv`; `./slipmat spotify --login` logs you in once |

## The automatic way (recommended)

```
./slipmat hello
```

The setup session builds all five Shortcuts **for your machine**, signed
locally and already pinned to the menu bar, then pops up an **"Add
Shortcut"** window for each — press Enter (or click the button), and the
next one pops up by itself (Apple requires that one human press; it's the
only manual part). Skipped this step before? Rerun `./slipmat hello` —
Enter keeps your saved folders.

After that:

- **Find them:** click the **Shortcuts icon** in the menu bar — two
  stacked, tilted squares, top right of the screen, near the clock. The
  five `[SLIPMAT …]` shortcuts are in its dropdown.
- **No icon?** On a MacBook with a notch, a full menu bar hides icons
  behind the notch — hold ⌘ and drag icons you don't need off the bar, or
  quit an app that lives up there. On newer macOS, if System Settings has a
  **Menu Bar** section, make sure Shortcuts is allowed there.
- **Icon, but no slipmat in it?** The dropdown shows the Shortcuts app's
  **"Menu Bar"** folder. Drag each `[SLIPMAT …]` card onto that folder, or
  select it → ⌘I → ✓ **"Pin in Menu Bar"**. No "Menu Bar" folder listed?
  Shortcuts → **Settings → Sidebar → tick "Menu Bar"**.
- **First click of each shortcut:** macOS asks whether to allow it — click
  Allow (Always Allow where offered). Once per shortcut; reinstalling one
  resets that, so it asks once more.

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

**[SLIPMAT WEBAUDIO]**
```
osascript "REPO/shortcuts/launch.applescript" "REPO" audio
```

**[SLIPMAT SPOTIFY]**
```
osascript "REPO/shortcuts/launch.applescript" "REPO" spotify
```

All five delegate to one on-disk launcher (`shortcuts/launch.applescript`),
so a `git pull` updates every Shortcut's behavior without touching the
Shortcuts app again. If a Shortcut ever behaves differently from running
slipmat in the terminal, it's usually a hand-built Shortcut with an old
command pasted inline — keep Shortcuts as one-line delegators.
