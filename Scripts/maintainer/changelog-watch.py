#!/usr/bin/env python3
"""Reads Claude Code's changelog for the two things this app wants from it.

They are not the same thing, and only one of them the changelog is any good at.

**What broke.** Nothing, usually -- and the changelog is the wrong place to look.
Every reading in docs/claude-code is observed behaviour, not a documented
interface: `queue-operation` records, `isSidechain`, `message.model`, the
`response` field that is not in `AskUserQuestionInput`'s schema at all. None of
that will ever get a changelog line, because none of it was ever announced.
Measured over the 30 releases to v2.1.234, the five entries that touched a pinned
surface all landed *before* the version its note was checked against -- the probes
had them first. So this half reports version drift and names the probes to re-run;
it does not pretend to read intent out of prose.

**What to build.** Here it earns its keep. Those same 30 releases carried 747
bullets, of which about 17% touch a surface this app reads and roughly 3% are
worth acting on -- a bad ratio to read by hand every morning, a cheap one to
filter. Additive fields are the good case: effort landing on every assistant turn
(v2.1.212) and depth-2 subagent text forwarding (v2.1.219) were both features this
app could adopt, announced plainly, and invisible to every probe we have.

Three ways it goes quiet rather than wrong:

  The watermark is `~/.claude/dex/changelog.json`, written by `--seen`,
  and `docs/claude-code/changelog-read.json` in the repo, written by
  `--seen --shared`; the further of the two counts.
  It started out derived from the readings' *highest* `(CLI v2.1.NNN)`
  -- but those markers move when a probe is re-run, and re-checking a behaviour
  is not the same act as reading for things to build. Marking one done was
  silently marking the other, and on 2026-08-21 it did: probes had just been run
  to 2.1.238, the newest release there was, so the first read it ever
  offered covered nothing at all. A machine that has never marked one now falls
  back to the *oldest* pin instead. It reads more than it has to -- some of that
  span was read once, by whoever wrote the note -- but it cannot skip a release
  nothing ever read, which is the failure that has no symptom.

  Headings are matched as `## <version>` against the raw file on GitHub. A
  restructured changelog parses to nothing, which reads exactly like a quiet week,
  so a quiet week prints how many releases it did parse and the newest of them.

  The filter is keywords. A surface renamed upstream stops matching and drops into
  `unsorted`, which is shown as a count and printed in full under --all -- read it
  when a release looks emptier than it should. Surfaces beat the soft noise list,
  so an enterprise fix that touches the transcript is kept; the foreign list beats
  the surfaces, because a Remote Control entry mentioning permission modes is still
  a Remote Control entry.

Usage:  python3 Scripts/maintainer/changelog-watch.py [--since X.Y.Z] [--until X.Y.Z]
                                           [--all] [--probes] [--seen [X.Y.Z]]
        python3 Scripts/maintainer/changelog-watch.py --given-up | --followed-up X.Y.Z
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CHANGELOG = "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"

# A bullet that opens "Remote Control:" is not about this app whatever else it
# mentions, so these are read before the surfaces rather than after them.
FOREIGN = r"remote control|\bvs ?code\b|jetbrains|claude in chrome|\bwindows\b|\blinux\b|cygwin|powershell|\bwsl\b|vertex|bedrock|gitlab|bitbucket|self-hosted runner|screen reader|voice mode"

SURFACES = [
    ("transcript", r"transcript|\.jsonl|sidechain|ai-title|session title|queued message|session director"),
    ("sdk", r"\bsdk\b|stream-json|control request|headless|canusetool|set_model|--input-format|print mode|\bfork(ed|s|ing)?\b"),
    ("subagent", r"subagent|agent tool|task tool|forward-subagent-text|background agent"),
    ("model", r"/model\b|model id|modeloverrides|\beffort\b|1m context"),
    ("permission", r"permission mode|askuserquestion|plan mode|exitplanmode|updatedinput|permission prompt"),
    ("context", r"context window|/context\b|compact|cache (?:read|write|token)|token (?:usage|count|total|budget|telemetry)|session cost"),
    ("commands", r"slash command|slash menu|bundled skill|\bhooks?\b"),
    ("fleet", r"sendmessage|listagents|cross-session|claude agents|agents? view|agent list|session name|task[- ]notification"),
]

NOISE = [
    ("enterprise", r"gateway|enterprise|managed settings|opentelemetry|\botel\b|otlp|mtls|usage-credits|/login|oauth|\badmin\b"),
    ("plugins/MCP", r"\bplugins?\b|marketplace|\bmcp\b|sandbox"),
    ("other clients", r"claude desktop|\bdesktop\b|claude\.ai/code|cloud session"),
    ("terminal UI", r"fullscreen|vim mode|keybinding|\bterminal\b|redraw|spinner|scrollback|footer|glyph|\bpicker\b"),
    ("forges", r"github app|\bglab\b|claude-code-action|\bgh cli\b"),
]


def version(text):
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", text or "")
    return tuple(int(g) for g in m.groups()) if m else None


def spell(v):
    return ".".join(str(n) for n in v) if v else "unknown"


def readings(folder):
    """Each file in docs/claude-code: its pinned versions and its probe."""
    out = []
    for path in sorted(folder.rglob("*.md")):
        body = path.read_text()
        m = re.match(r"# (.+?) \((.*?)\)\s*$", body.split("\n", 1)[0])
        if not m:
            continue
        title, pins = m.groups()
        cli = re.search(r"CLI v(\d+\.\d+\.\d+)", pins)
        sdk = re.search(r"SDK (\d+\.\d+\.\d+)", pins)
        probes = re.findall(r"(Scripts/(?:[\w-]+/)?[\w.-]+\.py|Sidecar/test/(?:[\w-]+/)?[\w.-]+\.ts)", body)
        out.append(
            {
                "title": title,
                "cli": version(cli.group(1)) if cli else None,
                "sdk": sdk.group(1) if sdk else None,
                "probes": sorted(set(probes)),
            }
        )
    return out


def watch_file():
    """Beside `fleet.json`, under whatever `CLAUDE_CONFIG_DIR` names."""
    config = os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"
    return Path(os.path.expanduser(config)) / "dex" / "changelog.json"


def local_mark():
    mark = read_mark(watch_file())
    return mark


def shared_file():
    """The mark kept in the repo, so a fresh checkout starts where the readings were last read to."""
    return Path(__file__).resolve().parents[2] / "docs" / "claude-code" / "changelog-read.json"


def read_mark(path):
    try:
        return version(json.loads(path.read_text()).get("seen"))
    except (OSError, ValueError, AttributeError):
        return None


def seen_mark(shared=None):
    """The further of this machine's mark and the repo's, or just the one asked for."""
    if shared is not None:
        return read_mark(shared_file()) if shared else local_mark()
    marks = [m for m in (local_mark(), read_mark(shared_file())) if m]
    return max(marks) if marks else None


def read_file(path):
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_file(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    data["updatedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    return path


def mark_seen(v, shared=False):
    path = shared_file() if shared else watch_file()
    data = read_file(path)
    data["seen"] = spell(v)
    return write_file(path, data)


def given_up():
    """Ranges marked read without being followed up, oldest first, until someone does."""
    ranges = read_file(shared_file()).get("givenUp")
    return [r for r in ranges if isinstance(r, dict)] if isinstance(ranges, list) else []


def give_up(start, end, kept=None):
    data = read_file(shared_file())
    ranges = [r for r in given_up() if r.get("from") != spell(start)]
    entry = {"from": spell(start), "to": spell(end), "on": datetime.now(timezone.utc).strftime("%Y-%m-%d")}
    if kept:
        entry["kept"] = kept
    data["givenUp"] = sorted(ranges + [entry], key=lambda r: version(r.get("from") or "") or ())
    return write_file(shared_file(), data)


def followed_up(start):
    data = read_file(shared_file())
    ranges = given_up()
    left = [r for r in ranges if r.get("from") != spell(start)]
    if len(left) == len(ranges):
        return False
    if left:
        data["givenUp"] = left
    else:
        data.pop("givenUp", None)
    write_file(shared_file(), data)
    return True


def installed():
    try:
        r = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return version(r.stdout) if r.returncode == 0 else None


def bundled():
    """The `claude` the SDK ships, which is the one the app's sessions run.

    A different binary from the one above and on a different clock: that one
    updates itself, this one moves when `Scripts/make-app.sh` moves the pin.
    They were ten releases apart before the build started moving it.
    """
    binary = (
        Path(__file__).resolve().parents[2]
        / "Sidecar/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude"
    )
    if not binary.exists():
        return None
    try:
        r = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return version(r.stdout) if r.returncode == 0 else None


def measured_against(reading, live, ships):
    """Which of the two a reading was checked against.

    Every probe runs the bundled CLI, so a reading with one answers to that. A
    note with no probe could be either, so it answers with whichever is further
    ahead — the reading that gets re-checked needlessly is the cheaper mistake
    of the two.
    """
    if reading["probes"]:
        return ships
    return max(v for v in (live, ships) if v) if (live or ships) else None


def fetch():
    req = urllib.request.Request(CHANGELOG, headers={"User-Agent": "changelog-watch"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8")


def releases(text):
    for m in re.finditer(r"^## +(\S+)[^\n]*\n(.*?)(?=^## |\Z)", text, re.M | re.S):
        v = version(m.group(1))
        if v:
            yield v, re.findall(r"^[-*] +(.+?)(?=\n[-*] |\n#|\Z)", m.group(2), re.M | re.S)


def sort(bullet):
    low = bullet.lower()
    if re.search(FOREIGN, low):
        return "drop", ["another client or platform"]
    tags = [name for name, pat in SURFACES if re.search(pat, low)]
    if tags:
        return "keep", tags
    for name, pat in NOISE:
        if re.search(pat, low):
            return "drop", [name]
    return "unsorted", []


def wrap(text, width, indent):
    text = " ".join(text.split())
    lines, line = [], ""
    for word in text.split(" "):
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = f"{line} {word}".strip()
    lines.append(line)
    return f"\n{indent}".join(lines)


def report_probes(pinned, live, ships=None):
    print(f"claude {spell(live)} installed" if live else "claude not on PATH")
    print(
        f"claude {spell(ships)} in the SDK — what the app's sessions run"
        if ships
        else "no SDK installed under Sidecar/ — nothing to say what the app's sessions run"
    )
    checkable = [r for r in pinned if r["cli"]]
    if not checkable:
        print(f"  none of the {len(pinned)} readings carries a (CLI vX.Y.Z) marker to check.\n")
        return

    # Said rather than implied: with nothing to compare against, every reading
    # is trivially not-behind, which reads exactly like every reading being current.
    if not (live or ships):
        print(f"  neither CLI could be read, so the {len(checkable)} pinned readings"
              " were checked against nothing.\n")
        return

    against = {r["title"]: measured_against(r, live, ships) for r in checkable}
    stale = [r for r in checkable if against[r["title"]] and r["cli"] < against[r["title"]]]
    if not stale:
        print(f"  all {len(checkable)} CLI-pinned readings are at their own CLI's version.\n")
        return
    print(f"  {len(stale)} of {len(pinned)} readings pinned below the CLI that answers for them:\n")
    for r in sorted(stale, key=lambda r: r["cli"]):
        probe = ", ".join(r["probes"]) if r["probes"] else "the note names no probe"
        print(f"  v{spell(r['cli'])} → {spell(against[r['title']])}  {r['title']}")
        print(f"            {probe}")
    print()


def mark_hint(newest, ceiling):
    """The exact command to mark what this run just showed.

    Printed rather than left to a bare `--seen`, which marks the installed CLI.
    That binary skips releases and updates on its own clock, so against an
    unbounded read it names a version short of what was covered -- which the
    mark now refuses rather than takes, but a refused mark is a reading that
    never gets recorded at all.
    """
    top = min(v for v in (newest, ceiling) if v) if (newest and ceiling) else (newest or ceiling)
    if not top:
        return
    print(f"when you're done reading: python3 Scripts/maintainer/changelog-watch.py --seen {spell(top)}\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", help="version to report from (default: the mark, else the oldest reading)")
    ap.add_argument("--until", help="version to stop at (default: no cap)")
    ap.add_argument("--all", action="store_true", help="print unsorted bullets too")
    ap.add_argument("--probes", action="store_true", help="version drift only, no fetch")
    ap.add_argument(
        "--seen",
        nargs="?",
        const="installed",
        help="mark the changelog read to this version and stop. The bare form marks the"
        " installed CLI, which lags what a run without --until has just shown you --"
        " a report prints the version to mark instead",
    )
    ap.add_argument(
        "--shared",
        action="store_true",
        help="with --seen, move the mark kept in the repo (docs/claude-code/changelog-read.json)"
        " rather than this machine's",
    )
    ap.add_argument(
        "--give-up",
        nargs=2,
        metavar=("FROM", "TO"),
        help="record in the repo's mark that FROM → TO was marked read without being followed up",
    )
    ap.add_argument("--kept", help="with --give-up, the attempt's report, relative to the nightly's folder")
    ap.add_argument("--given-up", action="store_true", help="list the ranges given up on, one per line")
    ap.add_argument("--followed-up", metavar="FROM", help="take the given-up range starting at FROM off the list")
    ap.add_argument("--readings", default=None, help="folder of readings (default: docs/claude-code)")
    args = ap.parse_args()

    if args.give_up:
        start, end = (version(v) for v in args.give_up)
        if not start or not end:
            sys.exit(f"--give-up {' '.join(args.give_up)} needs two X.Y.Z versions")
        print(f"recorded {spell(start)} → {spell(end)} as given up in {give_up(start, end, args.kept)}")
        return
    if args.given_up:
        for r in given_up():
            kept = f"; the attempt is {r['kept']} on the build machine" if r.get("kept") else ""
            print(f"{r.get('from')} → {r.get('to')} (given up {r.get('on', '?')}{kept})")
        return
    if args.followed_up:
        start = version(args.followed_up)
        if not start:
            sys.exit(f"--followed-up {args.followed_up} is not an X.Y.Z version")
        if not followed_up(start):
            sys.exit(f"no given-up range starts at {spell(start)}")
        print(f"took {spell(start)} off the given-up list in {shared_file()}")
        return

    if args.shared and args.seen is None:
        sys.exit("--shared only goes with --seen")
    if args.seen is not None:
        # Marking and reading are separate runs. Taken together the range flags
        # look like they bound the mark and don't, so the mark would quietly land
        # somewhere other than where the reading stopped.
        if args.since or args.until:
            sys.exit("--seen doesn't take a range; say --seen <version> to mark a specific one")
        mark = installed() if args.seen == "installed" else version(args.seen)
        if not mark:
            sys.exit(
                "nothing to mark: claude is not on PATH"
                if args.seen == "installed"
                else f"--seen {args.seen} is not an X.Y.Z version"
            )
        # Never backward. The mark means "read through here", and no run
        # un-reads anything: a bare `--seen` names a CLI that lags the fetch, a
        # `--until` run prints a hint for its own ceiling, and a fetch served
        # from a stale cache reports a newest below the one already stored.
        # Each would silently re-offer entries that were read.
        current = seen_mark(shared=args.shared)
        if current and current > mark:
            print(
                f"already marked read through {spell(current)};"
                f" {spell(mark)} would walk it back, so it was left alone"
            )
            return
        if current == mark:
            print(f"already marked read through {spell(mark)}")
            return
        print(f"marked read through {spell(mark)} in {mark_seen(mark, shared=args.shared)}")
        return

    md = Path(args.readings) if args.readings else Path(__file__).resolve().parents[2] / "docs" / "claude-code"
    if not md.is_dir():
        sys.exit(f"no readings folder at {md}")

    pinned = readings(md)
    if not pinned:
        sys.exit(f"{md} holds no readings -- does each file still open with '# Title (CLI vX.Y.Z)'?")
    report_probes(pinned, installed(), bundled())
    if args.probes:
        return

    ceiling = None
    if args.until:
        ceiling = version(args.until)
        if not ceiling:
            sys.exit(f"--until {args.until} is not an X.Y.Z version")

    if args.since:
        mark, source = version(args.since), "--since"
        if not mark:
            sys.exit(f"--since {args.since} is not an X.Y.Z version")
    elif (marked := seen_mark()) is not None:
        mark, source = marked, "the mark"
    else:
        pins = [r["cli"] for r in pinned if r["cli"]]
        if not pins:
            sys.exit(f"{md} pins no CLI version -- pass --since, or restore the (CLI vX.Y.Z) markers")
        # The oldest, not the newest: see the module docstring. A pin moves when
        # its probe is re-run, so the highest one is evidence about a behaviour
        # rather than about what has been read.
        mark, source = min(pins), "the oldest reading, never marked"

    try:
        text = fetch()
    except (urllib.error.URLError, TimeoutError) as e:
        sys.exit(f"could not fetch the changelog: {e}")

    parsed = list(releases(text))
    fresh = [(v, bs) for v, bs in parsed if v > mark and (ceiling is None or v <= ceiling)]
    total = sum(len(bs) for _, bs in fresh)
    span = f"since {spell(mark)}" if ceiling is None else f"{spell(mark)} → {spell(ceiling)}"
    print(f"{span} ({source}): {len(fresh)} releases, {total} bullets")
    newest = max((v for v, _ in parsed), default=None)
    if not total:
        print(f"  {len(parsed)} releases parsed, newest {spell(newest)}.\n")
        mark_hint(newest, ceiling)
        return

    kept, dropped, unsorted = [], {}, []
    for v, bullets in fresh:
        for b in bullets:
            verdict, tags = sort(b)
            if verdict == "keep":
                kept.append((v, tags, b))
            elif verdict == "unsorted":
                unsorted.append((v, b))
            else:
                dropped[tags[0]] = dropped.get(tags[0], 0) + 1

    print(f"  {len(kept)} touch a surface this app reads ({len(kept) * 100 // total}%)")
    if dropped:
        tally = ", ".join(f"{k} {n}" for k, n in sorted(dropped.items(), key=lambda kv: -kv[1]))
        print(f"  {sum(dropped.values())} noise: {tally}")
    print(f"  {len(unsorted)} unsorted\n")

    shown = None
    for v, tags, b in kept:
        if v != shown:
            print(f"## {spell(v)}")
            shown = v
        print(f"  [{'/'.join(tags)}] {wrap(b, 88, '      ')}")
    print()

    if args.all and unsorted:
        print("## unsorted")
        for v, b in unsorted:
            print(f"  {spell(v)}  {wrap(b, 88, '            ')}")
        print()

    mark_hint(newest, ceiling)


if __name__ == "__main__":
    main()
