"""slipmat's Spotify ripper — built on mr-rippah by cvdub (github.com/cvdub/mr-rippah),
used and extended here with cvdub's blessing.

Upgrades over upstream mr-rippah:
  · quality guard — a lower-than-320 vorbis serve FAILS the track instead of
    slipping a degraded file through
  · rate-limit survival — adaptive pacing, a circuit breaker, and a 60s stall
    timeout on librespot's hang-forever stream fetch
  · resume ledger — finished tracks are skipped instantly on relaunch
  · album links (upstream takes playlists and tracks only)
  · AAC-320 via Apple's encoder (or 16-bit AIFF), full tags, true-square art,
    optional atomic delivery into Music.app's Automatically Add folder
  · opt-in: [SPOT] album suffix, ghost-track ledger (unplayable tracks)
Settings arrive as SLIPMAT_* environment variables from engine/slipmat-spotify.
"""
import base64
import logging
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import warnings
import webbrowser
from datetime import datetime
from collections.abc import Callable
from dataclasses import dataclass, field
from io import BytesIO
from pathlib import Path
from typing import Self

import requests
from librespot.audio.decoders import AudioQuality, VorbisOnlyAudioQuality
from librespot.core import Session
from librespot.metadata import AlbumId, PlaylistId, TrackId
from librespot.proto import Playlist4External_pb2 as Playlist4
from mutagen.aiff import AIFF
from mutagen.easyid3 import EasyID3
from mutagen.id3 import (
    APIC, COMM, ID3, TALB, TCOM, TDRC, TIT2, TPE1, TPE2, TPOS, TRCK, TSRC, TXXX,
)
from platformdirs import user_cache_dir, user_downloads_dir
from rich.progress import (
    BarColumn,
    MofNCompleteColumn,
    Progress,
    SpinnerColumn,
    TextColumn,
)

with warnings.catch_warnings(action="ignore", category=SyntaxWarning):
    from pydub import AudioSegment

SPOTIFY_CDN_URL = "https://i.scdn.co/image/"
# what Spotify really served (the quality guard rejects anything below it);
# shown in rekordbox's Composer column
SOURCE_STAMP = "src vorbis 320kbps"
SPOTIFY_PLAYLIST_URI_REGEX = re.compile(r"^spotify:playlist:[A-Za-z0-9]{22}$")
SPOTIFY_TRACK_URI_REGEX = re.compile(r"^spotify:track:[A-Za-z0-9]{22}$")
SPOTIFY_ALBUM_URI_REGEX = re.compile(r"^spotify:album:[A-Za-z0-9]{22}$")

type SpotifyPlaylistURI = str
type SpotifyTrackURI = str


logger = logging.getLogger(__name__)



def _squarify_jpeg(data: bytes) -> bytes:
    """Art law: covers must be true-square. Center-crop non-square Spotify art."""
    try:
        import io
        from PIL import Image
        im = Image.open(io.BytesIO(data))
        w, h = im.size
        if w == h:
            return data
        side = min(w, h)
        left = (w - side) // 2
        top = (h - side) // 2
        im = im.crop((left, top, left + side, top + side))
        out = io.BytesIO()
        im.convert("RGB").save(out, format="JPEG", quality=92)
        return out.getvalue()
    except Exception:
        return data



class _QualityFallbackGuard(logging.Handler):
    """librespot silently falls back to a lower vorbis tier (96/160k) when the
    320 file is missing from a (often rate-limit-stressed) response, logging
    only a warning. That warning must FAIL the rip — otherwise a degraded file
    lands looking like a 320 one. Disable with MR_RIPPAH_NO_QUALITY_GUARD=1."""
    def __init__(self):
        super().__init__(level=logging.WARNING)
        self.tripped = False
    def emit(self, record):
        try:
            if "quality couldn't be found" in record.getMessage():
                self.tripped = True
        except Exception:
            pass

_quality_guard = _QualityFallbackGuard()
logging.getLogger("Librespot:Player:VorbisOnlyAudioQuality").addHandler(_quality_guard)
logging.getLogger("Librespot:Player:FormatOnlyAudioQuality").addHandler(_quality_guard)


class RipFailedError(Exception):
    def __init__(
        self,
        message: str,
        uri: str,
        title: str | None = None,
        original_error: Exception | None = None,
        permanent: bool = False,
        artist: str | None = None,
    ):
        super().__init__(message)
        self.uri = uri
        self.title = title
        self.artist = artist
        self.original_error = original_error
        # permanent=True: the track itself can't be ripped (unplayable/local/
        # invalid URI) — says nothing about rate limits, so the circuit
        # breaker must ignore it.
        self.permanent = permanent


def _safe_name(name: str) -> str:
    """A filename-safe version of a Spotify title (no path separators, no
    colons — Finder shows ':' as '/')."""
    return name.replace("/", "-").replace(":", "-").strip().strip(".")


def make_unique_directory(path: Path):
    """Create a directory with a unique name, appending a number if it already exists.

    Args:
        path: The desired directory path.

    Returns:
        Path to the created directory. If the path exists, returns a path with
        a number appended (e.g., "dirname (1)", "dirname (2)").
    """
    if not path.exists():
        path.mkdir()
        return path

    # otherwise append a number
    i = 1
    while True:
        candidate = path.with_name(f"{path.name} ({i})")
        if not candidate.exists():
            candidate.mkdir()
            return candidate
        i += 1


@dataclass
class SpotifyPlaylist:
    name: str
    uri: SpotifyPlaylistURI
    snapshot_id: str
    track_uris: list[SpotifyTrackURI] = field(default_factory=list, repr=False)


@dataclass
class TrackRipResult:
    uri: str
    title: str | None
    success: bool = True
    failure_reason: str | None = None
    path: Path | None = None
    skipped: bool = False  # ledger skip: no network touched, no pacing owed


def spotify_oauth_callback(url: str) -> None:
    """Default OAuth callback that opens the authentication URL in a web browser.

    Args:
        url: The Spotify OAuth authentication URL to open.
    """
    webbrowser.open(url)


class MrRippah:
    """Spotify playlist ripper that downloads tracks as MP3 files with metadata.

    This class handles authentication with Spotify, downloading tracks from playlists,
    converting audio to MP3 format, and embedding ID3 metadata tags.

    Attributes:
        credentials_path: Path to Spotify credentials JSON file.
        download_directory: Directory where playlists will be downloaded.
        download_chunk_size: Size of chunks when streaming audio data.
        spotify_authentication_retries: Number of retry attempts for Spotify authentication.
        track_download_retries: Number of retry attempts for track downloads.
        retry_delay_seconds: Base delay in seconds between retry attempts.
        successful_download_delay_seconds: Delay between successful downloads to avoid rate limiting.
        spotify_oauth_callback: Callback function invoked with OAuth URL during authentication.
    """

    credentials_path: Path
    download_directory: Path
    download_chunk_size: int
    spotify_authentication_retries: int
    track_download_retries: int
    retry_delay_seconds: int
    successful_download_delay_seconds: int
    spotify_oauth_callback: Callable[[str], None]

    def __init__(
        self,
        credentials_path: Path | None = None,
        download_directory: Path | None = None,
        download_chunk_size: int = 65_536,
        spotify_authentication_retries: int = 5,
        track_download_retries: int = 5,
        retry_delay_seconds: int = 5,
        successful_download_delay_seconds: int = 5,
        spotify_oauth_callback: Callable[[str], None] = spotify_oauth_callback,
    ):
        """Initialize Mr. Rippah with configuration options.

        Args:
            credentials_path: Path to store Spotify credentials. Defaults to platform-specific
                cache directory if None.
            download_directory: Directory to save downloaded playlists. Defaults to user's
                Downloads folder if None.
            download_chunk_size: Size in bytes for streaming audio chunks. Defaults to 65536.
            spotify_authentication_retries: Maximum authentication retry attempts. Defaults to 5.
            track_download_retries: Maximum download retry attempts per track. Defaults to 5.
            retry_delay_seconds: Base delay between retries, multiplied by attempt number.
                Defaults to 5.
            successful_download_delay_seconds: Delay between successful track downloads to
                avoid rate limiting. Defaults to 5.
            spotify_oauth_callback: Callback function invoked with OAuth URL during authentication.
                Defaults to opening the URL in a web browser.
        """
        self.credentials_path = credentials_path or self.default_credentials_path()
        self.download_directory = download_directory or Path(user_downloads_dir())
        self.download_chunk_size = download_chunk_size
        self.spotify_authentication_retries = spotify_authentication_retries
        self.track_download_retries = track_download_retries
        self.retry_delay_seconds = retry_delay_seconds
        self.successful_download_delay_seconds = int(os.environ.get('MR_RIPPAH_DELAY', successful_download_delay_seconds))
        self.spotify_oauth_callback = spotify_oauth_callback
        self.__session: Session | None = None
        self.__api = None
        # Music delivery (opt-in): finished files are staged, fully converted AND
        # tagged, then atomically renamed into Music's watched Auto-Add folder.
        _aa = os.environ.get("SLIPMAT_AUTO_ADD", "")
        self.auto_add_directory = Path(_aa) if _aa else None
        # Ledger of every ripped URI: resume (skip already-ripped tracks) and a
        # guard against duplicate library imports.
        self.ledger_path = Path(os.environ.get(
            "SLIPMAT_SPOTIFY_LEDGER", str(Path.home() / ".slipmat" / "spotify-ledger.txt")))
        # Ghost tracks (opt-in): URIs Spotify still lists but no longer serves
        # audio for. Deduped list, raw material for hunting them elsewhere.
        _gh = os.environ.get("SLIPMAT_SPOTIFY_GHOSTS", "")
        self.ghost_ledger_path = Path(_gh) if _gh else None
        self._ghost_uris: set | None = None
        # Adaptive pacing (AIMD): Spotify grants ~25 fast key requests, then
        # refills ~1 per 35-40s; hammering past that escalates to session-kill.
        self._current_delay = successful_download_delay_seconds
        self._clean_streak = 0

    def _auto_add_enabled(self) -> bool:
        return self.auto_add_directory is not None and self.auto_add_directory.is_dir()

    def _ledger_set(self) -> set:
        """Ledger URIs, loaded once per process (re-reading the whole file for
        every track made big playlists crawl)."""
        if getattr(self, "_ledger_cache", None) is None:
            self._ledger_cache = set()
            try:
                for line in self.ledger_path.read_text().splitlines():
                    parts = line.split("\t")
                    if len(parts) >= 2:
                        self._ledger_cache.add(parts[1])
            except FileNotFoundError:
                pass
        return self._ledger_cache

    def _in_ledger(self, uri: str) -> bool:
        return uri in self._ledger_set()

    def _ledger_add(self, uri: str, title: str) -> None:
        self.ledger_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.ledger_path, "a") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M}\t{uri}\t{title}\n")
        self._ledger_set().add(uri)

    def _ghost_add(self, e: "RipFailedError") -> None:
        """Record a permanently unrippable (ghost) track, deduped by URI."""
        if self.ghost_ledger_path is None:
            return
        try:
            if self._ghost_uris is None:
                self._ghost_uris = set()
                if self.ghost_ledger_path.exists():
                    for line in open(self.ghost_ledger_path):
                        parts = line.split("\t")
                        if len(parts) >= 2:
                            self._ghost_uris.add(parts[1].strip())
            if e.uri in self._ghost_uris:
                return
            with open(self.ghost_ledger_path, "a") as f:
                f.write(f"{datetime.now():%Y-%m-%d %H:%M}\t{e.uri}\t"
                        f"{e.artist or '?'}\t{e.title or '?'}\t{e}\n")
            self._ghost_uris.add(e.uri)
        except Exception as ex:
            logger.debug(f"ghost-ledger write failed: {ex}")

    def _run_with_timeout(self, fn, timeout_seconds: int):
        """Run fn in a daemon thread; raise TimeoutError if it stalls.

        librespot's audio-key request has no timeout and hangs forever on a dead
        socket (observed after sustained rate limiting) — this bounds it.
        """
        result: dict = {}

        def runner():
            try:
                result["value"] = fn()
            except BaseException as e:
                result["error"] = e

        t = threading.Thread(target=runner, daemon=True)
        t.start()
        t.join(timeout_seconds)
        if t.is_alive():
            raise TimeoutError(f"stalled for {timeout_seconds}s")
        if "error" in result:
            raise result["error"]
        return result["value"]

    @property
    def _session(self) -> Session:
        """Get the active Spotify session.

        Returns:
            The active Session object.

        Raises:
            RuntimeError: If connect() has not been called or the session is closed.
        """
        if self.__session is None:
            raise RuntimeError(
                "Not connected to Spotify. Call connect() or use as a context manager."
            )
        return self.__session

    @property
    def _api(self):
        """Get the active Spotify API client.

        Returns:
            The active API client object.

        Raises:
            RuntimeError: If connect() has not been called or the session is closed.
        """
        if self.__api is None:
            raise RuntimeError(
                "Not connected to Spotify. Call connect() or use as a context manager."
            )
        return self.__api

    @staticmethod
    def default_credentials_path() -> Path:
        """Get the default path for storing Spotify credentials.

        Returns:
            Path to credentials.json in platform-specific cache directory.
        """
        return (
            Path(user_cache_dir("Mr. Rippah", ensure_exists=True)) / "credentials.json"
        )

    @staticmethod
    def spotify_url_to_uri(url: str) -> str:
        """Converts a Spotify web URL into a canonical Spotify URI.

        Args:
            uri: The Spotify URL (e.g., https://open.spotify.com/track/...)
                or URI to be normalized.

        Returns:
            The normalized Spotify URI (e.g., spotify:track:...) if a URL
            was provided and matched, otherwise returns the original string.
        """
        if url.startswith(("http://", "https://")):
            match = re.search(r"/(playlist|track|album)/([A-Za-z0-9]{22})", url)
            if match:
                type_, item_id = match.groups()
                return f"spotify:{type_}:{item_id}"
        return url

    @staticmethod
    def is_spotify_playlist_uri(playlist_uri: str) -> bool:
        """Check if string is a valid Spotify playlist URI.

        Args:
            playlist_uri: String to validate as Spotify playlist URI.

        Returns:
            True if valid Spotify playlist URI format, False otherwise.
        """
        return bool(SPOTIFY_PLAYLIST_URI_REGEX.match(playlist_uri))

    @staticmethod
    def is_spotify_album_uri(album_uri: str) -> bool:
        return bool(SPOTIFY_ALBUM_URI_REGEX.match(album_uri))

    @staticmethod
    def is_spotify_track_uri(track_uri: str) -> bool:
        """Check if string is a valid Spotify track URI.

        Args:
            track_uri: String to validate as Spotify track URI.

        Returns:
            True if valid Spotify track URI format, False otherwise.
        """
        return bool(SPOTIFY_TRACK_URI_REGEX.match(track_uri))

    def connect(self) -> Self:
        """Start Spotify session with OAuth authentication.

        Opens a browser window for OAuth authentication if credentials are not cached.
        Retries connection attempts with exponential backoff on failure.

        Returns:
            Self for method chaining.

        Raises:
            ConnectionRefusedError: If authentication fails after all retry attempts.
            RuntimeError: If session creation fails after all retry attempts.
        """
        config_builder = Session.Configuration.Builder()
        config_builder.set_stored_credential_file(str(self.credentials_path))
        librespot_config = config_builder.build()
        session_builder = Session.Builder(librespot_config)

        logger.info("Connecting to Spotify")
        success_page = (
            "<html><body>"
            "<h1>Login Successful</h1>"
            "<p>You can close this window now.</p>"
            "<script>setTimeout(() => {window.close()}, 100);</script>"
            "</body></html>"
        )
        num_retries = 0
        while num_retries < self.spotify_authentication_retries:
            try:
                self.__session = session_builder.oauth(
                    self.spotify_oauth_callback, success_page
                ).create()
            except (RuntimeError, ConnectionRefusedError) as e:
                logger.debug(f"Failed to get librespot session: {e}")
                num_retries += 1
                if num_retries < self.spotify_authentication_retries:
                    wait_time = self.retry_delay_seconds * num_retries
                    logger.debug(f"Retrying in {wait_time} seconds")
                    time.sleep(wait_time)
                    logger.debug(f"Retry attempt {num_retries} for librespot session")
            else:
                self.__api = self.__session.api()
                break

        logger.debug("Successfully connected to Spotify")
        return self

    def close(self) -> None:
        """Close Spotify session and clean up resources.

        Safely closes the connection even if session was never established.
        """
        if self.__session is not None:
            try:
                self.__session.close()
                logger.debug("Closed Spotify connection")
            except AttributeError:
                logger.debug("Spotify connection already closed")
                pass
            self.__session = None
            self.__api = None

    def __enter__(self) -> Self:
        """Enter context manager and establish Spotify connection.

        Returns:
            Self for use in with statement.
        """
        return self.connect()

    def __exit__(self, exc_type, exc_value, traceback):
        """Exit context manager and close Spotify connection.

        Args:
            exc_type: Exception type if an exception occurred.
            exc_value: Exception instance if an exception occurred.
            traceback: Traceback object if an exception occurred.
        """
        self.close()

    def get_username(self) -> str:
        """Get the username of the currently authenticated Spotify user.

        Returns:
            The Spotify username.
        """
        return self._session.username()

    def get_current_user_playlists(self) -> list[SpotifyPlaylistURI]:
        """Get all playlist URIs for the currently authenticated user.

        Returns:
            List of Spotify playlist URIs (e.g., "spotify:playlist:...") owned by
            or followed by the current user.

        Raises:
            Exception: If the API request to fetch the user's playlists fails.
        """
        username = self._session.username()
        logger.debug(f"Getting Spotify playlists for {username=}")
        response = self._api.send(
            "GET", f"/playlist/v2/user/{username}/rootlist", None, None
        )
        if response.status_code != 200:
            raise Exception(f"Failed to fetch rootlist: {response.status_code}")

        root_list = Playlist4.SelectedListContent()
        root_list.ParseFromString(response.content)

        playlist_uris = []
        for item in root_list.contents.items:
            playlist_uri = item.uri
            if playlist_uri.startswith("spotify:playlist:"):
                playlist_uris.append(playlist_uri)

        return playlist_uris

    def get_playlist_tracks(self, playlist_uri: SpotifyPlaylistURI) -> SpotifyPlaylist:
        """Get all track URIs from a Spotify playlist.

        Args:
            playlist_uri: Spotify playlist URI (spotify:playlist:ID) or full URL
                (https://open.spotify.com/playlist/ID).

        Returns:
            List of track URIs (e.g., "spotify:track:...") contained in the playlist.

        Raises:
            ValueError: If playlist_uri is not a valid Spotify playlist URI or URL.
        """
        playlist_uri = self.spotify_url_to_uri(playlist_uri)
        if not self.is_spotify_playlist_uri(playlist_uri):
            raise ValueError(f"Invalid Spotify playlist URI: {playlist_uri}")

        playlist_id = PlaylistId.from_uri(playlist_uri)
        librespot_playlist = self._api.get_playlist(playlist_id)
        return SpotifyPlaylist(
            name=librespot_playlist.attributes.name,
            uri=playlist_uri,
            snapshot_id=base64.b64encode(librespot_playlist.revision).decode("utf-8"),
            track_uris=[item.uri for item in librespot_playlist.contents.items],
        )

    def get_album_tracks(self, album_uri: str) -> SpotifyPlaylist:
        """An album as a SpotifyPlaylist (disc order), so rip_playlist can take it."""
        album_uri = self.spotify_url_to_uri(album_uri)
        if not self.is_spotify_album_uri(album_uri):
            raise ValueError(f"Invalid Spotify album URI: {album_uri}")
        album = self._api.get_metadata_4_album(AlbumId.from_uri(album_uri))
        uris = [TrackId.from_hex(t.gid.hex()).to_spotify_uri()
                for disc in album.disc for t in disc.track]
        artist = album.artist[0].name if album.artist else "Unknown Artist"
        return SpotifyPlaylist(name=f"{artist} - {album.name}", uri=album_uri,
                               snapshot_id="", track_uris=uris)

    def rip_playlist(
        self,
        playlist_uri: str,
        download_directory: Path | None = None,
        show_progress: bool = True,
    ) -> list[TrackRipResult]:
        """Download all tracks in Spotify playlist.

        Accepts playlist URI (spotify:playlist:ID) or full Spotify URL. Creates a unique
        subdirectory for the playlist and downloads all tracks with metadata and album art.
        Progress bar is automatically disabled in verbose/debug mode or non-terminal outputs.

        Args:
            playlist_uri: Spotify playlist URI (spotify:playlist:ID) or full URL
                (https://open.spotify.com/playlist/ID).
            download_directory: Directory to save ripped playlist. Defaults to instance's
                download_directory if None. A subdirectory with the playlist ID will be created.
            show_progress: Whether to display progress bar. Automatically disabled if logging
                level is DEBUG or output is not a TTY. Defaults to True.

        Returns:
            List of TrackRipResult objects containing success/failure status for each track.

        Raises:
            ValueError: If playlist_uri is not a valid Spotify playlist URI or URL.
        """
        start_time = time.perf_counter()

        if download_directory is None:
            download_directory = self.download_directory

        _u = self.spotify_url_to_uri(playlist_uri)
        playlist = (self.get_album_tracks(_u) if self.is_spotify_album_uri(_u)
                    else self.get_playlist_tracks(_u))
        logger.info(f"{playlist.name} — {len(playlist.track_uris):,} tracks")
        if self._auto_add_enabled():
            playlist_download_directory = None
        else:
            # a folder named for the playlist/album (not its opaque ID)
            download_directory.mkdir(parents=True, exist_ok=True)
            playlist_download_directory = make_unique_directory(
                download_directory / (_safe_name(playlist.name) or playlist.uri.split(":")[-1])
            )
        results = []

        # Disable progress bar in verbose/debug mode or non-terminal outputs
        show_progress = (
            show_progress
            and logger.getEffectiveLevel() > logging.DEBUG
            and sys.stdout.isatty()
        )

        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            disable=not show_progress,
            transient=True,
        ) as progress:
            num_tracks = len(playlist.track_uris)
            task = progress.add_task("Ripping!", total=num_tracks)
            for track_num, track_uri in enumerate(playlist.track_uris, start=1):
                logger.debug(f"{track_uri} Ripping track {track_num:,}/{num_tracks:,}")
                try:
                    result = self.rip_track(track_uri, playlist_download_directory)
                except RipFailedError as e:
                    logger.warning(
                        f"{e.uri} RIP FAILED ({e}): {e.title or 'unknown title'}"
                        + (" — track itself is unrippable; not a rate-limit signal"
                           if e.permanent else "")
                    )
                    result = TrackRipResult(
                        uri=e.uri,
                        title=e.title,
                        success=False,
                        failure_reason=str(e),
                    )
                    if e.permanent:
                        # Unplayable/local/invalid tracks fail instantly on every
                        # run — they say nothing about Spotify's mood and must
                        # not trip the rate-limit breaker.
                        self._ghost_add(e)
                        results.append(result)
                        progress.update(task, advance=1)
                        continue
                    self._fail_streak = getattr(self, "_fail_streak", 0) + 1
                    if self._fail_streak >= 4:
                        cool = int(os.environ.get("MR_RIPPAH_BREAKER_COOL", "900"))
                        logger.warning(
                            f"Circuit breaker: {self._fail_streak} consecutive failures — cooling {cool}s and rebuilding session"
                        )
                        time.sleep(cool)
                        try:
                            self.close()
                        except Exception:
                            pass
                        self.connect()
                        self._fail_streak = 0
                        self._current_delay = max(self._current_delay, 35)
                else:
                    if result.skipped:
                        # a ledger skip touched no server — no
                        # inter-track delay, and it neither earns nor spends
                        # adaptive-pacing credit.
                        results.append(result)
                        progress.update(task, advance=1)
                        continue
                    self._fail_streak = 0
                    self._clean_streak += 1
                    if (
                        self._clean_streak >= 5
                        and self._current_delay
                        > self.successful_download_delay_seconds
                    ):
                        self._current_delay = max(
                            self.successful_download_delay_seconds,
                            int(self._current_delay * 0.75),
                        )
                        self._clean_streak = 0
                        logger.debug(
                            f"Pacing: easing inter-track delay to {self._current_delay}s"
                        )
                    if self._current_delay > 0 and track_num != num_tracks:
                        logger.debug(
                            f"Waiting {self._current_delay} seconds to start next download"
                        )
                        time.sleep(self._current_delay)
                results.append(result)
                progress.update(task, advance=1)

        num_successes = sum(1 for r in results if r.success)
        end_time = time.perf_counter()
        logger.info(
            f"Ripped {num_successes:,}/{num_tracks:,} tracks in {end_time - start_time:,.2f} seconds"
        )
        if playlist_download_directory is None:
            logger.info("Tracks delivered to the Music Auto-Add folder (importing into library)")
        else:
            logger.info(f"Playlist saved to {playlist_download_directory}")
        return results

    def rip_track(
        self, track_uri: str, download_directory: Path | None
    ) -> TrackRipResult:
        """rip_track with a guarantee: a failure mid-convert never leaves the
        Music staging dir behind in $TMPDIR."""
        self._staging = None
        try:
            return self._rip_track(track_uri, download_directory)
        finally:
            if self._staging is not None:
                shutil.rmtree(self._staging, ignore_errors=True)
                self._staging = None

    def _rip_track(
        self, track_uri: str, download_directory: Path | None
    ) -> TrackRipResult:
        """Download a single track with metadata and album art.

        Downloads track audio stream, converts to MP3, and embeds ID3 tags including title,
        artist, album, track number, date, ISRC, Spotify URIs, and album art. Handles track
        re-linking for alternative versions and retries failed downloads with exponential backoff.

        Track is saved to: download_directory/Artist/Album/TrackNumber - Title.mp3

        Args:
            track_uri: Spotify track URI (spotify:track:ID) or just the track ID. Local
                tracks (spotify:local:) are not supported.
            download_directory: Base directory for saving the track. The track will be
                organized into Artist/Album subdirectories. Defaults to instance's
                download_directory if None.

        Returns:
            TrackRipResult with success status and track information.

        Raises:
            RipFailedError: If track is local, unplayable, has invalid URI, or fails to
                download after all retry attempts.
        """
        download_directory = download_directory or self.download_directory

        track_uri = self.spotify_url_to_uri(track_uri)

        if track_uri.startswith("spotify:local:"):
            raise RipFailedError("Can't rip local tracks", track_uri, permanent=True)

        if not track_uri.startswith("spotify:"):
            track_uri = f"spotify:track:{track_uri}"
        try:
            track_id = TrackId.from_uri(track_uri)
        except RuntimeError:
            raise RipFailedError("Invalid track URI", track_uri, permanent=True)

        if self._in_ledger(track_uri):
            logger.info(
                f"{track_uri} Already ripped per ledger — skipping "
                f"(remove its line from {self.ledger_path.name} to re-rip)"
            )
            return TrackRipResult(uri=track_uri, title="(already ripped — skipped)",
                                  skipped=True)

        logger.debug(f"{track_uri} Getting track metadata")
        metadata = self._api.get_metadata_4_track(track_id)
        if metadata.alternative:
            track_id = TrackId.from_hex(metadata.alternative[0].gid.hex())
            metadata = self._api.get_metadata_4_track(track_id)
            logger.debug(f"{track_uri} Re-linked to {track_id.to_spotify_uri()}")

        if not metadata.file and not metadata.alternative:
            raise RipFailedError("Track is unplayable", track_uri, title=metadata.name,
                                 permanent=True,
                                 artist=", ".join(a.name for a in metadata.artist))

        logger.debug(f"{track_uri} Saving track stream")

        def _fetch_stream() -> BytesIO:
            track_stream = self._session.content_feeder().load(
                track_id,
                VorbisOnlyAudioQuality(AudioQuality.VERY_HIGH),
                True,  # Pre-load
                None,
            )
            buf = BytesIO()
            while True:
                chunk = track_stream.input_stream.stream().read(
                    self.download_chunk_size
                )
                if not chunk:
                    break
                buf.write(chunk)
            return buf

        num_retries = 0
        while num_retries < self.track_download_retries:
            try:
                audio_bytes = self._run_with_timeout(_fetch_stream, 60)
            except TimeoutError:
                # Dead socket (Spotify killed the session): librespot would hang
                # forever here. Rebuild the session and retry the same track.
                num_retries += 1
                logger.warning(
                    f"{track_uri} Stream fetch stalled — rebuilding Spotify session"
                )
                try:
                    self.close()
                except Exception:
                    pass
                self.connect()
                self._current_delay = max(self._current_delay, 35)
                self._clean_streak = 0
                if num_retries >= self.track_download_retries:
                    raise RipFailedError(
                        "Failed to get track stream (stalled)",
                        track_uri,
                        title=metadata.name,
                    )
            except Exception as e:
                num_retries += 1
                if "audio key" in str(e).lower():
                    # Rate limited: raise the inter-track delay toward the
                    # observed refill rate (~1 key per 35-40s) instead of
                    # burning 2-3 denied requests per track.
                    if self._current_delay < 35:
                        self._current_delay = 35
                        logger.info(
                            "Pacing: rate limit hit — inter-track delay now 35s"
                        )
                    self._clean_streak = 0
                logger.debug(f"{track_uri} Failed to rip: {e}")
                wait_time = self.retry_delay_seconds * num_retries
                logger.debug(f"Retrying in {wait_time} seconds")
                time.sleep(wait_time)
                if num_retries >= self.track_download_retries:
                    logger.error(
                        f"{track_uri} Failed to rip after {num_retries} retries"
                    )
                    raise RipFailedError(
                        "Failed to get track stream",
                        track_uri,
                        title=metadata.name,
                        original_error=e,
                    )
            else:
                break

        out_format = os.environ.get("MR_RIPPAH_FORMAT", "aac320")  # "aac320" (default) or "aiff"
        if _quality_guard.tripped and os.environ.get("MR_RIPPAH_NO_QUALITY_GUARD") != "1":
            _quality_guard.tripped = False
            raise RipFailedError(
                "Quality guard: Spotify served a lower tier than 320 — rejected",
                track_uri,
                title=metadata.name,
            )
        _quality_guard.tripped = False
        # byte-level stream fingerprint + optional raw ogg dump (bulletproof
        # serve-identity evidence, immune to any spectral-analysis artifact)
        import hashlib as _hl
        audio_bytes.seek(0)
        _sha = _hl.sha256(audio_bytes.getbuffer()).hexdigest()
        logger.debug(f"STREAM-SHA256 {track_uri} {_sha} bytes={audio_bytes.getbuffer().nbytes}")
        _dump_dir = os.environ.get("MR_RIPPAH_DUMP_OGG")
        if _dump_dir:
            os.makedirs(_dump_dir, exist_ok=True)
            with open(os.path.join(_dump_dir, track_uri.split(":")[-1] + ".ogg"), "wb") as _df:
                _df.write(audio_bytes.getbuffer())
        ext = ".m4a" if out_format == "aac320" else ".aiff"
        logger.debug(f"{track_uri} Converting track to {out_format}")
        audio_bytes.seek(0)
        audio = AudioSegment.from_file(audio_bytes, format="ogg")
        deliver_auto_add = self._auto_add_enabled()
        staging_dir = None

        _safe = _safe_name

        if deliver_auto_add:
            # Stage OUTSIDE the watched folder: Music imports files the moment it
            # sees them, so the file must be complete (converted AND tagged)
            # before it becomes visible there.
            staging_dir = Path(tempfile.mkdtemp(prefix="slipmat-spotify-"))
            self._staging = staging_dir
            track_path = staging_dir / (
                f"{_safe(metadata.artist[0].name)} - {_safe(metadata.name)}{ext}"
            )
        else:
            # flat "Artist - Title", like every other slipmat audio rip
            download_directory.mkdir(parents=True, exist_ok=True)
            stem = f"{_safe(metadata.artist[0].name)} - {_safe(metadata.name)}"
            track_path = download_directory / f"{stem}{ext}"
            n = 2
            while track_path.exists():
                track_path = download_directory / f"{stem} ({n}){ext}"
                n += 1
        if out_format == "aac320":
            audio.export(
                track_path,
                format="ipod",
                parameters=["-c:a", "aac_at", "-b:a", "320k"],
            )
        else:
            audio.export(
                track_path,
                format="aiff",
                parameters=["-c:a", "pcm_s16be"],
            )

        if out_format == "aac320":
            logger.debug(f"{track_uri} Saving track metadata to MP4 tags")
            from mutagen.mp4 import MP4, MP4Cover, MP4FreeForm
            mp = MP4(track_path)
            mp["\xa9nam"] = [metadata.name]
            mp["\xa9ART"] = [", ".join(a.name for a in metadata.artist)]
            mp["aART"] = [metadata.album.artist[0].name]
            mp["\xa9alb"] = [metadata.album.name + (" [SPOT]" if os.environ.get("SLIPMAT_SPOT_TAG") == "1" else "")]
            mp["trkn"] = [(metadata.number, 0)]
            mp["disk"] = [(metadata.disc_number, 0)]
            date = metadata.album.date
            mp["\xa9day"] = [f"{date.year}-{date.month:02}-{date.day:02}"]
            spotify_track_uris = [track_uri]
            final_track_uri = track_id.to_spotify_uri()
            if final_track_uri != track_uri:
                spotify_track_uris.append(final_track_uri)
            mp["----:com.apple.iTunes:spotify_uris"] = [
                MP4FreeForm(u.encode("utf-8")) for u in spotify_track_uris
            ]
            mp["\xa9cmt"] = [f"src=vorbis 320kbps -> aac_at 320 | {track_uri}"]
            # the source stamp rides in Composer — see engine/slipmat-audio
            mp["\xa9wrt"] = [SOURCE_STAMP]
            if metadata.album.cover_group.image:
                logger.debug(f"{track_uri} Downloading album art")
                image = metadata.album.cover_group.image[-1]
                file_id_hex = image.file_id.hex()
                cdn_url = f"{SPOTIFY_CDN_URL}{file_id_hex}"
                response = requests.get(cdn_url)
                if response.status_code == 200:
                    mp["covr"] = [MP4Cover(_squarify_jpeg(response.content), imageformat=MP4Cover.FORMAT_JPEG)]
            mp.save()
        else:
            logger.debug(f"{track_uri} Saving track metadata to ID3 tags")
            aiff = AIFF(track_path)
            if aiff.tags is None:
                aiff.add_tags()
            audio = aiff.tags
            audio.add(TIT2(encoding=3, text=[metadata.name]))
            audio.add(TPE1(encoding=3, text=[", ".join(a.name for a in metadata.artist)]))
            audio.add(TPE2(encoding=3, text=[metadata.album.artist[0].name]))
            audio.add(TALB(encoding=3, text=[metadata.album.name + (" [SPOT]" if os.environ.get("SLIPMAT_SPOT_TAG") == "1" else "")]))
            audio.add(TRCK(encoding=3, text=[str(metadata.number)]))
            audio.add(TPOS(encoding=3, text=[str(metadata.disc_number)]))

            date = metadata.album.date
            audio.add(TDRC(encoding=3, text=[f"{date.year}-{date.month:02}-{date.day:02}"]))

            for external_id in metadata.external_id:
                if external_id.type == "isrc":
                    audio.add(TSRC(encoding=3, text=[external_id.id]))
                    break

            spotify_track_uris = [track_uri]
            final_track_uri = track_id.to_spotify_uri()
            if final_track_uri != track_uri:
                # Store original and re-linked URI in ID3 tag
                spotify_track_uris.append(final_track_uri)
            audio.add(TXXX(desc="spotify_uris", text=spotify_track_uris))
            audio.add(
                COMM(
                    encoding=3,
                    lang="eng",
                    desc="",
                    text=[f"src=vorbis 320kbps | {track_uri}"],
                )
            )
            audio.add(TCOM(encoding=3, text=[SOURCE_STAMP]))

            # Download album art
            if metadata.album.cover_group.image:
                logger.debug(f"{track_uri} Downloading album art")
                image = metadata.album.cover_group.image[-1]
                file_id_hex = image.file_id.hex()
                cdn_url = f"{SPOTIFY_CDN_URL}{file_id_hex}"
                response = requests.get(cdn_url)
                if response.status_code == 200:
                    audio.add(
                        APIC(
                            encoding=3,
                            mime="image/jpeg",
                            type=3,
                            desc="0",
                            data=_squarify_jpeg(response.content),
                        )
                    )

            aiff.save()

        if deliver_auto_add:
            dest = self.auto_add_directory / track_path.name
            n = 2
            while dest.exists():
                dest = self.auto_add_directory / (
                    f"{track_path.stem} ({n}){track_path.suffix}"
                )
                n += 1
            try:
                os.rename(track_path, dest)  # atomic on same volume
            except OSError:
                # Cross-volume fallback: copy invisibly (dot-name), then rename
                part = self.auto_add_directory / f".{dest.name}.part"
                shutil.copy2(track_path, part)
                os.rename(part, dest)
                track_path.unlink()
            if staging_dir is not None:
                shutil.rmtree(staging_dir, ignore_errors=True)
            track_path = dest
            logger.debug(f"{track_uri} Delivered to Music Auto-Add: {dest.name}")

        self._ledger_add(
            track_uri, f"{metadata.artist[0].name} - {metadata.name}"
        )
        return TrackRipResult(uri=track_uri, title=metadata.name, path=track_path)
