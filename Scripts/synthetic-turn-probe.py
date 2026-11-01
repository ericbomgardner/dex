#!/usr/bin/env python3
"""Says whether the CLI still marks the turns it writes itself.

When a request fails, Claude Code writes an assistant turn of its own — an
overload, a dropped connection, a session limit, a login it wants — and marks it
twice. Both marks are read, and each fails quietly on its own.

**`<synthetic>` where the model id goes.** `TranscriptDocument.model` reads the
newest turn's model, so a placeholder taken for a model puts `<synthetic>` in the
badge under the composer and leaves it there — the badge moves only when a turn
names a model, and a session writing these has stopped answering. The stretch
where it is wrong is exactly the stretch it lasts.

**`isApiErrorMessage` on the failures alone.** It sorts an error from the CLI's
other synthetic line — "No response requested.", its word that a resumed
conversation had nothing to add. Lose it and a rate limit draws as calmly as a
shrug. Lose `<synthetic>` and both draw as the model's own prose, which is how
"You've hit your session limit" comes to read as a sentence about itself.

Neither can be waited for, so this forces one: a model name that cannot resolve
fails before the request is made. The turn it writes carries the same two marks
as an overload, at no cost and in about a second.

Runs in a scratch directory, and asks for a session that never starts.

Usage:  python3 Scripts/synthetic-turn-probe.py
"""

import json, os, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from claude_cli import bundled_cli, keyed

SYNTHETIC = "<synthetic>"  # TranscriptText.syntheticModel
UNRESOLVABLE = "zzz-not-a-model"


def transcripts(root):
    found = {}
    for base, _, names in os.walk(root):
        for name in names:
            if name.endswith(".jsonl"):
                path = os.path.join(base, name)
                found[path] = os.path.getmtime(path)
    return found


# Any live session writes under the same root while this runs, so newest-changed alone can pick one of those.
def opened_in(path, cwd):
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if record.get("cwd"):
                return os.path.realpath(record["cwd"]) == cwd
    return False


def main():
    root = os.path.expanduser("~/.claude/projects")
    before = transcripts(root)

    env, args = keyed(dict(os.environ), "synthetic-turn-probe")
    with tempfile.TemporaryDirectory() as scratch:
        scratch = os.path.realpath(scratch)
        subprocess.run(
            [bundled_cli(), *args, "-p", "--model", UNRESOLVABLE, "hello"],
            cwd=scratch, env=env, capture_output=True, text=True, timeout=180,
        )

    after = transcripts(root)
    fresh = [p for p, at in after.items() if before.get(p) != at and opened_in(p, scratch)]
    if not fresh:
        print("no transcript was written — the CLI refused the model before opening a session.")
        print("Force the shape another way, or read one from an older session.")
        return 1

    written = max(fresh, key=lambda p: after[p])
    records = []
    with open(written, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                records.append(json.loads(line))
            except ValueError:
                continue

    version = next((r.get("version") for r in records if r.get("version")), None)
    print(f"{os.path.basename(written)}  (CLI {version or 'version unrecorded'})\n")

    errors = [r for r in records if r.get("type") == "assistant" and r.get("isApiErrorMessage")]
    synthetic = [r for r in records
                 if (r.get("message") or {}).get("model") == SYNTHETIC]

    for record in errors or synthetic:
        blocks = (record.get("message") or {}).get("content") or []
        text = " ".join(b.get("text", "") for b in blocks if isinstance(b, dict))
        print(f"  model              {(record.get('message') or {}).get('model')!r}")
        print(f"  isApiErrorMessage  {record.get('isApiErrorMessage')!r}")
        print(f"  text               {' '.join(text.split())[:100]!r}")

    ok = True
    if not synthetic:
        print(f"\nno turn said {SYNTHETIC}. The CLI names the model on turns it wrote itself,\n"
              "  or marks them some other way. `TranscriptText.syntheticModel` is what to\n"
              "  change; until it is, the badge shows whatever this says instead.")
        ok = False
    if not errors:
        print("\nno turn carried `isApiErrorMessage`. A failure now draws in the pane as\n"
              "  quietly as the CLI's benign line. `TranscriptRecord.isApiErrorMessage`\n"
              "  is what to change.")
        ok = False
    if ok:
        print("\nboth marks held.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
