#!/usr/bin/env python3
"""Reads the mode vocabulary and writes it into the app.

`claude --help` prints it as `--permission-mode`'s `(choices: …)`, and the
SDK's `permissionMode` option takes the same names. That is the list the
composer's picker narrows down, so it comes from the CLI rather than from memory.

There are two vocabularies here and they do not agree. The offered list has
`manual`, `dontAsk` and `bypassPermissions`, none of which a transcript has ever
been seen to write; a transcript writes `default`, which that list omits. The
badge asks whether it recognises a mode, so it has to know both — reading
`default` as a name this build has never heard of would mark most sessions in
the list. The written list is checked against real transcripts here rather than
generated from them, since a mode nobody happens to have used lately is not a
mode that has gone.

`default` is dropped out of the list on the way through: sending no mode at all
already means the same thing, and the picker says so in words.

The probe also reports the plan shapes the app reads out of a transcript —
`ExitPlanMode` and its outcomes — so a change to either shows up here rather
than as an empty card. The live mode itself arrives on the host's socket now;
the transcript records for it are printed for the record only.

Usage:  python3 Scripts/permission-mode-probe.py [--dry-run]
"""

import glob
import json
import os
import re
import subprocess
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from claude_cli import bundled_cli

OUT = os.path.join(os.path.dirname(__file__), "..",
                   "Sources", "DexCore", "Actions", "PermissionModes.swift")

PROJECTS = os.path.expanduser("~/.claude/projects")

CHOICES = re.compile(r"--permission-mode\s+<mode>.*?\(choices:\s*(.+?)\)", re.S)

# Sending no flag already means this, and two menu entries that do the same
# thing is one too many.
SAME_AS_NO_FLAG = "default"

# What the app has seen transcripts write. Not generated — a mode nobody used
# this week has not gone anywhere.
WRITTEN = ["auto", "default", "acceptEdits", "plan"]

TEMPLATE = '''import Foundation

/// The names `--permission-mode` takes, read off the CLI by
/// `Scripts/permission-mode-probe.py` — `claude --help` prints them as that
/// flag's `choices`. Recorded against **CLI v{version}**; re-run the probe when
/// the CLI moves and the list will move with it.
///
/// The list says what to offer, not what to allow: a name that falls off it
/// still dispatches. `default` is not in here — sending no flag already means
/// that, and the picker says so in words.
public enum PermissionModes {{

    public static let version = "{version}"

    public static let all: [String] = [
{entries}
    ]

    /// What a transcript writes, which is not what the flag takes: `default` is
    /// written often and the flag refuses it, while `manual`, `dontAsk` and
    /// `bypassPermissions` are the other way round. A mode is only unrecognised
    /// if it is in neither — reading `default` as a name this build has never
    /// heard of would mark most of the list.
    public static let written: [String] = [
{writtens}
    ]

    public static func recognises(_ name: String) -> Bool {{
        all.contains(name) || written.contains(name)
    }}
}}
'''


def help_text():
    try:
        done = subprocess.run([bundled_cli(), "--help"], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        sys.exit("claude --help did not answer inside a minute")
    return done.stdout + done.stderr


def choices(output):
    found = CHOICES.search(output)
    if not found:
        return []
    names = re.findall(r'"([^"]+)"', found.group(1))
    return [name for name in names if name != SAME_AS_NO_FLAG]


def version():
    out = subprocess.run([bundled_cli(), "--version"], capture_output=True, text=True).stdout
    return out.strip().split(" ")[0] or "unknown"


def newest_transcripts(limit):
    files = glob.glob(os.path.join(PROJECTS, "*", "*.jsonl"))
    files.sort(key=os.path.getmtime, reverse=True)
    return files[:limit]


def survey(limit=200):
    """What the transcripts on this machine actually carry."""
    seen = {}
    mode_record = None
    mode_field = None
    plan_keys = None
    plan_version = None
    approved = None
    rejected = None

    for path in newest_transcripts(limit):
        try:
            with open(path, errors="replace") as handle:
                lines = handle.readlines()
        except OSError:
            continue

        for line in lines:
            if '"permissionMode"' not in line and "ExitPlanMode" not in line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue

            mode = record.get("permissionMode")
            if isinstance(mode, str):
                seen[mode] = seen.get(mode, 0) + 1
                if record.get("type") == "permission-mode" and mode_record is None:
                    mode_record = sorted(record.keys())
                elif record.get("type") == "user" and mode_field is None:
                    mode_field = record.get("version")

            for block in (record.get("message") or {}).get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("name") == "ExitPlanMode" and plan_keys is None:
                    plan_keys = sorted((block.get("input") or {}).keys())
                    plan_version = record.get("version")
                if block.get("type") != "tool_result":
                    continue
                text = block.get("content")
                if not isinstance(text, str):
                    continue
                if text.startswith("User has approved your plan") and approved is None:
                    approved = (text.splitlines()[0], record.get("version"))
                if block.get("is_error") and "doesn't want to proceed" in text and rejected is None:
                    rejected = (text.split(".")[0] + ".", record.get("version"))

    return seen, mode_record, mode_field, plan_keys, plan_version, approved, rejected


def main():
    found = version()
    names = choices(help_text())
    if not names:
        # Better to keep the list that is there than to replace it with nothing.
        sys.exit("no (choices: …) beside --permission-mode in claude --help — has the flag changed?")

    print(f"{len(names)} modes --permission-mode takes, from CLI v{found}")
    for name in names:
        print(f"  {name}")

    seen, mode_record, mode_field, plan_keys, plan_version, approved, rejected = survey()

    print("\nwhat the transcripts here write:")
    for mode, count in sorted(seen.items(), key=lambda pair: -pair[1]):
        edge = "" if mode in names or mode == SAME_AS_NO_FLAG else "   <- the flag does not take this"
        print(f"  {mode:20} {count}{edge}")
    for mode in WRITTEN:
        if mode not in seen:
            print(f"  {mode:20} 0   <- pinned in PermissionModes.written, none found lately")

    print("\nwhat the transcript records for the live mode (informational — the app reads it off the socket):")
    print(f"  record of its own:  {mode_record or 'NOT FOUND'}")
    print(f"  field on a prompt:  {'permissionMode' if mode_field else 'NOT FOUND'}")

    print("\nhow the plan reaches the app (ToolCall.proposedPlan, TranscriptDocumentTests):")
    print(f"  ExitPlanMode input: {plan_keys or 'NOT FOUND — no plan in the newest transcripts'}"
          f"{f'  (v{plan_version})' if plan_version else ''}")
    if plan_keys is not None and "plan" not in plan_keys:
        print("  the plan is no longer recorded inline — proposedPlan now leans on planFilePath")
    print(f"  approved:           {approved[0] if approved else 'NOT FOUND'}"
          f"{f'  (v{approved[1]})' if approved else ''}")
    print(f"  rejected:           {rejected[0] if rejected else 'NOT FOUND'}"
          f"{f'  (v{rejected[1]})' if rejected else ''}")

    if "--dry-run" in sys.argv:
        return

    entries = "\n".join(f'        "{name}",' for name in names)
    writtens = "\n".join(f'        "{name}",' for name in WRITTEN)
    path = os.path.normpath(OUT)
    with open(path, "w") as handle:
        handle.write(TEMPLATE.format(version=found, entries=entries, writtens=writtens))
    print("\nwrote", path)


if __name__ == "__main__":
    main()
