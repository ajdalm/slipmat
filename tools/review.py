#!/usr/bin/env python3
# review.py — the tool's own look at its run logs: which detours have become habits.
#
# Every run writes one plain-text log under ~/.slipmat/logs/<YYYY-MM-DD>/. A sentence
# built for an occasional failure ("site refused the probe — retrying as a real
# browser …") can end up printing on EVERY run for one site. Each of those is a
# detour the engine takes every time: seconds spent, and a route that has to hit a
# wall before it works. This reads the logs, groups the runs by site, and reports
# the detours that most runs of a site take, so they can become the starting route.
#
#   review.py [DAYS|all] [--logs DIR] [--min N] [--share PCT] [--json]
#
#   DAYS         calendar days to read, counted back from today (default 30);
#                "all" reads every day folder
#   --logs DIR   the log root (default $SLIPMAT_LOGS, else ~/.slipmat/logs)
#   --min N      a site needs N runs before a habit is called (default 5)
#   --share PCT  a detour is a habit at PCT percent of a site's runs (default 50)
#   --json       the same data as one JSON object, nothing else
#
# Three sections: HABITS (per site, the detours at or over the share), OFTEN (the
# 15 most frequent detours that are no habit anywhere), FAILED RUNS (per site,
# logs whose name starts with ✗; a closed window and a canceled run are the
# person's own key and are never counted as failures).
#
# What counts as a detour line:
#   "  ! …"                       a warning
#   "  yt-dlp: ERROR: …"          the downloader's error text
#   "  probe …: ERROR: …"         the same, from the first read
#   "  …" (two spaces, no mark)   only when it carries a word from DETOUR_WORDS
# Telemetry (speed, got, check, source, addresses, paths, titles) never counts, a
# hand action (x, a stop, canceled, Interrupted by user) never counts, and nothing
# after the run's own closing "ERROR:" line counts: that text is the end of the
# road, and FAILED RUNS reports it.
#
# A line is reduced to a SHAPE so runs can be compared: addresses, paths, quoted
# strings, numbers and video ids are replaced by placeholders. Only shapes are
# printed: no run's address and no title leaves the logs.
#
# Standard library only; runs under python3 -I. Exit 0 whenever the logs could be
# read (none at all included), exit 2 on a bad argument.
import json
import os
import re
import sys
import textwrap
from datetime import date, timedelta

USAGE = "usage: review.py [DAYS|all] [--logs DIR] [--min N] [--share PCT] [--json]"
WIDTH = 100          # no output line is longer than this
SHAPE_MAX = 110      # a shape is cut here with …
OFTEN_ROWS = 15
ERROR_ROWS = 5
LOCAL = "local file"

# ── what a detour note says ──────────────────────────────────────────────────
# An unmarked note counts only when it carries one of these. Each entry is a
# word the engine uses when it has left its first route.
DETOUR_WORDS = (
    r"retry(?:ing)?",            # "retrying as a real browser", "one retry without …"
    r"re-read(?:ing)?",          # "cached source info didn't resolve — re-reading fresh"
    r"refused",                  # "site refused the probe", "impersonation: chrome refused"
    r"trying",                   # "embed-locked player URL — trying your embed pages"
    r"again",                    # "refused the page again"
    r"went blank",               # "the page went blank between the read and the download"
    r"hung up",                  # "their video server hung up on chrome"
    r"answered empty",           # "logged-in API answered empty"
    r"came back empty",
    r"recovered",
    r"step(?:ping|ped)? down",   # a resolution step-down the engine took itself
    r"did(?: not|n't)",
    r"could(?: not|n't)",
    r"unlocked",                 # "no browser fingerprint unlocked it"
    r"swap",                     # "manifest swap: … -> …"
    r"rescue",                   # "embed rescue: … -> …", "playlist rescue: … -> …"
    r"salvage",                  # "salvage merge (yt-dlp merge failed)"
    r"stall(?:ed|s|ing)?",       # "stall: 12MB in hand …"
    r"still reading",            # a slow first read
    r"tripwire",                 # "[tripwire] probe took 40s"
    r"restart(?:ed|ing)?",       # "pieces: now -N 4 (clean restart)"
    r"fall(?:ing|s)? back|fell back|fallback",
    r"failed",
)
DETOUR = re.compile(r"(?<![\w-])(?:" + "|".join(DETOUR_WORDS) + r")(?![\w-])", re.I)

# Unmarked notes that are measurements, receipts, or carry a title or a file
# name. Checked before the vocabulary, so a title holding "again" never counts.
TELEMETRY = (
    "[speed]", "got:", "check:", "source:", "downloaded", "packing", "encoding",
    "encode flags:", "live selector:", "curve ledger:", "eta check:",
    "estimate check:", "probe check:", "probe: skipped", "capture window",
    "name bump:", "smart title:", "also on this page", "also-kept:", "heads-up:",
    "nmx concurrency:", "newsmax page:", "file ", "length ", "audio ", "mode ",
)
TITLE_ECHO = re.compile(r" · \d{1,2}\.\d{1,2}\.\d{2}$")     # "<title> · <channel> · 11.12.26"
BARE = re.compile(r"(?:[a-z][a-z0-9+.-]*:|/|~/)\S", re.I)   # a bare address or path

# The person's own key: never a detour, whatever marker the line carries.
HAND = re.compile(
    r"Interrupted by user|\bcancell?ed\b|\bCtrl-C\b|\(x\)|(?<![\w-])x(?![\w-])"
    r"|\bstopped by\b|\b(?:the|a|to) stop\b|\bwindow closed\b|didn't get \"")

ERROR_LINE = re.compile(r"(?:yt-dlp|probe(?: \([^)]*\))?): ERROR:")
TOOL_WARNING = re.compile(r"(?:yt-dlp|probe(?: \([^)]*\))?): WARNING:")   # the downloader's aside
RECOVERED = "recovered): ERROR:"     # an error the run got past: never the reason it failed

# ── a line's shape ───────────────────────────────────────────────────────────
ADDRESS = re.compile(
    r"(?:[a-z][a-z0-9+.-]*://|\bwww\.)\S+"                  # scheme://… or www.…
    r"|(?<![\w.@/-])(?:[a-z0-9-]+\.)+[a-z]{2,}/\S*", re.I)  # host.tld/…
PATH = re.compile(r"(?<![\w<.>])(?:~|/(?:Users|Volumes|private|tmp|var|home|opt))/.*")
QUOTED = re.compile(r'"[^"]*"|“[^”]*”')
EXTRACTOR_ID = re.compile(r"\[([A-Za-z][\w:+.-]*)\] ([^\s:\]]+):")   # "[RumbleEmbed] v7g2w2k:"
NUMBER = re.compile(
    r"\b(mp[34]|m4[av]|h26[45]|vp0?[89]|av0?1|e?ac3|x26[45]|m3u8)\b"  # names, kept as they are
    r"|[~≈]?\d+(?:[.,:：-]\d+)*(?:x\d+)?"
    r"(?:\s?(?:[KMGT]i?B(?:/s)?|kbps|fps)\b|[KMGTpsmh]\b|%)?")
SPACES = re.compile(r"\s+")


def _address(m):
    """<address>, keeping punctuation that closed the sentence around it."""
    tail = re.search(r"[)\].,;:'\"]*$", m.group(0)).group(0)
    return "<address>" + tail


def shape_of(text):
    """Reduce one log sentence to its shape."""
    s = ADDRESS.sub(_address, text)
    s = PATH.sub("<path>", s)
    s = QUOTED.sub('"…"', s)
    m = EXTRACTOR_ID.search(s)
    if m:
        s = s[:m.start()] + "[" + m.group(1) + "] <id>:" + s[m.end():]
        if len(m.group(2)) >= 6:
            s = s.replace(m.group(2), "<id>")
    s = NUMBER.sub(lambda n: n.group(1) or "#", s)
    s = SPACES.sub(" ", s).strip()
    if len(s) > SHAPE_MAX:
        s = s[:SHAPE_MAX - 1].rstrip() + "…"
    return s


def detour_of(line):
    """(kind, sentence) when the line is a detour, else None."""
    if not line.startswith("  ") or line[2:3] in ("", " "):
        return None
    body = line[2:].rstrip()
    if body.startswith("! "):
        kind, text = "warn", body[2:]
    elif ERROR_LINE.match(body):
        kind, text = "error", body
    elif body[0] in "+?|→✓✗":
        return None
    else:
        if body.startswith(TELEMETRY) or BARE.match(body) or TITLE_ECHO.search(body):
            return None
        if TOOL_WARNING.match(body):
            return None
        if not DETOUR.search(body):
            return None
        kind, text = "note", body
    if HAND.search(text):
        return None
    return kind, text


# ── one run ──────────────────────────────────────────────────────────────────
HOST_PREFIXES = ("www.", "m.", "mobile.", "player.")
HOST_ALIASES = {"youtu.be": "youtube.com"}
HOSTLIKE = re.compile(r"(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:[/?#]|$)", re.I)
URL_HOST = re.compile(r"[a-z][a-z0-9+.-]*://(?:[^/?#@\s]*@)?(\[[^\]]*\]|[^/?#:\s]*)", re.I)


def host_of(address):
    """The site a run's address belongs to; a path or anything else = local file."""
    m = URL_HOST.match(address)
    if m:
        host = m.group(1)
    elif HOSTLIKE.match(address):
        host = re.split(r"[/?#:]", address, 1)[0]
    else:
        return LOCAL
    host = host.lower().strip(".")
    stripped = True
    while stripped:
        stripped = False
        for prefix in HOST_PREFIXES:
            if host.startswith(prefix) and "." in host[len(prefix):]:
                host, stripped = host[len(prefix):], True
    return HOST_ALIASES.get(host, host) or LOCAL


NAME_HEAD = re.compile(r"\d{6}[ _]?")


def status_of(name):
    """ok / failed / closed / canceled, from the log's file name."""
    rest = NAME_HEAD.sub("", name, 1).lstrip()
    if not rest.startswith("✗"):
        return "ok"
    word = rest[1:].lstrip()
    for own in ("closed", "canceled"):
        if word == own + ".log" or word.startswith(own + " "):
            return own
    return "failed"


def seconds_of(clock):
    """'1:02:03' or '0:44' as seconds, None when it is not a clock."""
    parts = clock.strip().split(":")
    if not parts or not all(p.isdigit() for p in parts):
        return None
    total = 0
    for p in parts:
        total = total * 60 + int(p)
    return total


def read_run(path, day, name):
    """One log as a dict, or None for an unreadable or empty file."""
    try:
        with open(path, "rb") as fh:
            text = fh.read().decode("utf-8", errors="replace")
    except OSError:
        return None
    if not text.strip():
        return None
    host, shapes, last_error, elapsed, closed = None, {}, None, None, False
    for line in text.splitlines():
        if host is None and line.startswith("url:"):
            host = host_of(line[4:].strip())
            continue
        if line.startswith("total elapsed:"):
            elapsed = seconds_of(line[14:])
            continue
        at = line.find("ERROR:")
        if at >= 0:
            if RECOVERED not in line:
                last_error = line[at:]
            if at == 0:
                closed = True       # the run's own closing error: the rest is its epitaph
        if closed:
            continue
        found = detour_of(line)
        if found:
            shapes.setdefault(shape_of(found[1]), found[0])
    return {"day": day, "host": host or LOCAL, "status": status_of(name),
            "shapes": shapes, "elapsed": elapsed,
            "error": shape_of(last_error) if last_error else None}


DAY_DIR = re.compile(r"\d{4}-\d{2}-\d{2}$")


def read_runs(root, days):
    """Every run in the day folders inside the window, oldest day first."""
    try:
        names = sorted(n for n in os.listdir(root) if DAY_DIR.match(n))
    except OSError:
        return []
    oldest = None if days is None else (date.today() - timedelta(days=days - 1)).isoformat()
    runs = []
    for day in names:
        if oldest and day < oldest:
            continue
        folder = os.path.join(root, day)
        try:
            logs = sorted(n for n in os.listdir(folder) if n.endswith(".log"))
        except OSError:
            continue
        for name in logs:
            run = read_run(os.path.join(folder, name), day, name)
            if run:
                runs.append(run)
    return runs


# ── the report ───────────────────────────────────────────────────────────────
def median(values):
    values = sorted(values)
    if not values:
        return None
    mid = len(values) // 2
    return values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) // 2


def tally(runs):
    """host -> {runs, shape -> [count, newest day, kind]}, plus the same over all runs."""
    hosts, overall = {}, {}
    for run in runs:
        h = hosts.setdefault(run["host"], {"runs": [], "shapes": {}})
        h["runs"].append(run)
        for shape, kind in run["shapes"].items():
            for table in (h["shapes"], overall):
                row = table.setdefault(shape, [0, "", kind])
                row[0] += 1
                row[1] = max(row[1], run["day"])
    return hosts, overall


def find_habits(hosts, min_runs, share):
    habits = []
    for host, h in hosts.items():
        n = len(h["runs"])
        if n < min_runs:
            continue
        rows = [{"shape": s, "kind": kind, "runs": count, "of": n,
                 "share_pct": round(100.0 * count / n, 1), "last_seen": last}
                for s, (count, last, kind) in h["shapes"].items()
                if count * 100 >= share * n]
        if not rows:
            continue
        rows.sort(key=lambda r: (-r["runs"], r["kind"] == "error", r["shape"]))
        named = set(r["shape"] for r in rows)
        affected = sum(1 for run in h["runs"] if named.intersection(run["shapes"]))
        habits.append({"host": host, "runs": n, "affected_runs": affected,
                       "median_elapsed_s": median([r["elapsed"] for r in h["runs"]
                                                   if r["elapsed"] is not None]),
                       "shapes": rows})
    habits.sort(key=lambda h: (-h["affected_runs"], h["host"]))
    return habits


def find_often(hosts, overall, habits):
    taken = set(row["shape"] for h in habits for row in h["shapes"])
    rows = []
    for shape, (count, last, kind) in overall.items():
        if shape in taken:
            continue
        best = min(((-h["shapes"][shape][0], host) for host, h in hosts.items()
                    if shape in h["shapes"]))
        rows.append({"shape": shape, "kind": kind, "runs": count, "host": best[1],
                     "host_runs_with": -best[0], "host_runs": len(hosts[best[1]]["runs"]),
                     "last_seen": last})
    rows.sort(key=lambda r: (-r["runs"], r["shape"]))
    return rows[:OFTEN_ROWS]


def find_failed(hosts):
    rows, errors, silent = [], {}, 0
    for host, h in hosts.items():
        counts = {"failed": 0, "closed": 0, "canceled": 0}
        for run in h["runs"]:
            if run["status"] == "ok":
                continue
            counts[run["status"]] += 1
            if run["status"] != "failed":
                continue
            if run["error"]:
                errors[run["error"]] = errors.get(run["error"], 0) + 1
            else:
                silent += 1
        if counts["failed"]:
            rows.append(dict(host=host, runs=len(h["runs"]), **counts))
    rows.sort(key=lambda r: (-r["failed"], r["host"]))
    top = sorted(errors.items(), key=lambda e: (-e[1], e[0]))[:ERROR_ROWS]
    return {"hosts": rows, "errors": [{"shape": s, "runs": n} for s, n in top],
            "without_error": silent}


def build(root, days, min_runs, share):
    runs = read_runs(root, days)
    hosts, overall = tally(runs)
    habits = find_habits(hosts, min_runs, share)
    seen_days = sorted(set(r["day"] for r in runs))
    return {"logs_dir": root, "days": days, "min_runs": min_runs, "share_pct": share,
            "runs": len(runs), "days_read": len(seen_days),
            "first_day": seen_days[0] if seen_days else None,
            "last_day": seen_days[-1] if seen_days else None,
            "hosts": len(hosts), "habits": habits,
            "often": find_often(hosts, overall, habits), "failed": find_failed(hosts)}


# ── plain text ───────────────────────────────────────────────────────────────
def clock_of(seconds):
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return "%d:%02d:%02d" % (h, m, s) if h else "%d:%02d" % (m, s)


def plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def wrapped(text, indent):
    pad = " " * indent
    parts = textwrap.wrap(text, WIDTH - indent, break_on_hyphens=False)
    return [pad + part for part in parts or [""]]


def render(data, tty):
    bold = (lambda s: "\033[1m" + s + "\033[0m") if tty else (lambda s: s)
    dim = (lambda s: "\033[2m" + s + "\033[0m") if tty else (lambda s: s)
    out = []
    if not data["runs"]:
        return wrapped("no run logs under " + data["logs_dir"], 0)
    out += wrapped("slipmat review · %s · %s (%s → %s) · %s" % (
        plural(data["runs"], "run"), plural(data["days_read"], "day"),
        data["first_day"], data["last_day"], plural(data["hosts"], "site")), 0)

    if data["habits"]:
        out += [""] + wrapped("HABITS · a detour that %s%% or more of a site's runs take "
                              "(sites with %d or more runs)"
                              % (("%g" % data["share_pct"]), data["min_runs"]), 0)
        for h in data["habits"]:
            took = h["median_elapsed_s"]
            head = plural(h["runs"], "run") + (
                " · a run takes %s (median)" % clock_of(took) if took is not None else "")
            out += ["", bold(h["host"]) + dim(" · " + head)]
            for row in h["shapes"]:
                out.append(dim("  %d of %d runs · last seen %s"
                               % (row["runs"], row["of"], row["last_seen"])))
                out += wrapped(row["shape"], 6)

    if data["often"]:
        out += [""] + wrapped("OFTEN · the %d most frequent detours that are no habit above "
                              "(k of n = runs with it, of that site's runs)" % OFTEN_ROWS, 0)
        out.append("")
        for row in data["often"]:
            out.append(dim("  %s · mostly %s (%d of %d) · last seen %s" % (
                plural(row["runs"], "run"), row["host"], row["host_runs_with"],
                row["host_runs"], row["last_seen"])))
            out += wrapped(row["shape"], 6)

    failed = data["failed"]
    if failed["hosts"]:
        out += [""] + wrapped("FAILED RUNS · logs whose name starts with ✗ (a closed window "
                              "and a canceled run are the person's own key, never a failure)", 0)
        out.append("")
        wide = max(len(r["host"]) for r in failed["hosts"])
        for r in failed["hosts"]:
            own = "".join(" · %d %s" % (r[k], k) for k in ("closed", "canceled") if r[k])
            out.append("  " + bold(r["host"].ljust(wide)) + dim(
                "  %d failed of %s%s" % (r["failed"], plural(r["runs"], "run"), own)))
        if failed["errors"]:
            out += ["", "  the last ERROR of the failed runs, most common first"]
            for e in failed["errors"]:
                out.append(dim("  " + plural(e["runs"], "run")))
                out += wrapped(e["shape"], 6)
        if failed["without_error"]:
            out.append(dim("  %s failed with no ERROR line in the log"
                           % plural(failed["without_error"], "run")))

    if not data["habits"]:
        out += ["", "no detour has become a habit on any site"]
    return out


# ── the command line ─────────────────────────────────────────────────────────
def bad(why):
    sys.stderr.write("review: %s · %s\n" % (why, USAGE))
    sys.exit(2)


def number(text, what, low, high=None, kind=int):
    try:
        value = kind(text)
    except ValueError:
        bad("%s takes a number, got %r" % (what, text))
    if value != value or value < low or (high is not None and value > high):
        bad("%s out of range: %s" % (what, text))
    return value


def parse(argv):
    opts = {"days": 30, "min": 5, "share": 50, "json": False,
            "logs": os.environ.get("SLIPMAT_LOGS") or os.path.expanduser("~/.slipmat/logs")}
    days_given = False
    args = list(argv)
    while args:
        arg = args.pop(0)
        name, eq, value = arg.partition("=")
        if arg in ("-h", "--help"):
            print(USAGE)
            sys.exit(0)
        if arg == "--json":
            opts["json"] = True
        elif name in ("--logs", "--min", "--share"):
            if not eq:
                if not args:
                    bad(name + " needs a value")
                value = args.pop(0)
            if name == "--logs":
                if not value:
                    bad("--logs needs a folder")
                opts["logs"] = os.path.expanduser(value)
            elif name == "--min":
                opts["min"] = number(value, "--min", 1)
            else:
                share = number(value, "--share", 0, 100, float)
                if share <= 0:
                    bad("--share out of range: " + value)
                opts["share"] = int(share) if share == int(share) else share
        elif arg.startswith("-") and not arg.lstrip("-").isdigit():
            bad("unknown option " + arg)
        elif days_given:
            bad("one DAYS only, got a second: " + arg)
        else:
            days_given = True
            opts["days"] = None if arg == "all" else number(arg, "DAYS", 1, 100000)
    return opts


def main(argv):
    opts = parse(argv)
    data = build(opts["logs"], opts["days"], opts["min"], opts["share"])
    if opts["json"]:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0
    tty = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
    print("\n".join(render(data, tty)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except OSError:
            pass
        sys.exit(0)
