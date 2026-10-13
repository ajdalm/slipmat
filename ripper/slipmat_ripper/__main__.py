"""python -m slipmat_ripper <spotify link> — driven by engine/slipmat-spotify.

The CLI shape follows mr-rippah's (cvdub); settings arrive as SLIPMAT_* env
vars so the bash wrapper stays the single place that reads ~/.slipmat/config.
"""
import argparse
import logging
import os
import sys
import time
from pathlib import Path

from rich import box
from rich.console import Console
from rich.logging import RichHandler
from rich.table import Table

from .rippah import MrRippah


def main() -> int:
    ap = argparse.ArgumentParser(prog="slipmat spotify",
                                 description="rip a Spotify track, album or playlist")
    ap.add_argument("uri", nargs="?", help="Spotify track / album / playlist link or URI")
    ap.add_argument("--login", action="store_true",
                    help="log in to Spotify now (browser) and exit — no rip")
    ap.add_argument("-c", "--clear-spotify-credentials", action="store_true",
                    help="forget the saved Spotify login (the next rip asks again)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    handlers = [RichHandler(show_time=False, show_path=False, show_level=False,
                            markup=False, rich_tracebacks=True)]
    # run log: a plain file handler — never a pipe/pty wrapper around the ripper
    log_path = os.environ.get("SLIPMAT_LOG")
    if log_path:
        fh = logging.FileHandler(log_path)
        fh.setFormatter(logging.Formatter("%(asctime)s %(message)s", "%H:%M:%S"))
        handlers.append(fh)
    logging.basicConfig(level=logging.WARNING, format="%(message)s", handlers=handlers)
    log = logging.getLogger("slipmat_ripper")
    log.setLevel(logging.DEBUG if args.verbose else logging.INFO)

    if args.clear_spotify_credentials:
        MrRippah.default_credentials_path().unlink(missing_ok=True)
        log.info("Saved Spotify login cleared — the next rip opens the login page.")

    if args.login:
        creds = MrRippah.default_credentials_path()
        if creds.exists():
            log.info("✓ already logged in to Spotify — nothing to do.")
            return 0
        with MrRippah(download_directory=Path.home() / "Downloads" / "SLIPMAT"):
            pass
        if creds.exists():
            log.info("✓ logged in to Spotify — the login is saved for every future rip.")
            return 0
        log.error("Spotify login didn't finish — the first Spotify rip will ask again.")
        return 1
    if not args.uri:
        ap.error("a Spotify link is required (or --login)")

    uri = MrRippah.spotify_url_to_uri(args.uri.strip())
    is_list = MrRippah.is_spotify_playlist_uri(uri) or MrRippah.is_spotify_album_uri(uri)
    if not is_list and not MrRippah.is_spotify_track_uri(uri):
        log.error(f"Not a Spotify track, album or playlist link: {args.uri}")
        return 2

    outdir = Path(os.environ.get("SLIPMAT_SPOTIFY_OUTDIR") or Path.home() / "Downloads" / "SLIPMAT")
    with MrRippah(download_directory=outdir) as mr:
        if is_list:
            results = mr.rip_playlist(uri)
        else:
            t0 = time.perf_counter()
            with Console().status("Ripping track…"):
                try:
                    results = [mr.rip_track(uri, download_directory=None)]
                except Exception as e:  # RipFailedError and friends
                    log.error(f"RIP FAILED ({e})")
                    return 1
            r = results[0]
            if r.path:
                log.info(f"Ripped in {time.perf_counter() - t0:,.1f}s → {r.path}")

    failures = [r for r in results if not r.success]
    if failures:
        table = Table(title=f"{len(failures):,} tracks didn't rip", box=box.SIMPLE,
                      title_style="bold red", title_justify="left")
        table.add_column("Reason", style="yellow", no_wrap=True)
        table.add_column("Title", no_wrap=True)
        table.add_column("URI", no_wrap=True)
        for r in failures:
            table.add_row(r.failure_reason or "", r.title or "<unknown>", r.uri)
        Console().print(table)
    return 0 if any(r.success for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
