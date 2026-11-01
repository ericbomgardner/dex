#!/usr/bin/env python3
"""Reads the model names `--model` takes and writes them into the app.

`claude -p "/model"` prints what it is on now and, under `Available:`, every
name it will take. That is the list the composer's picker offers, so it comes
from the CLI rather than from memory.

`default` is dropped on the way through: sending no `--model` at all already
means the same thing, and the picker says so in words.

Usage:  python3 Scripts/model-alias-probe.py [--dry-run]
"""

import os
import re
import subprocess
import sys
import tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from claude_cli import bundled_cli

OUT = os.path.join(os.path.dirname(__file__), "..",
                   "Sources", "DexCore", "Actions", "ModelAliases.swift")

AVAILABLE = re.compile(r"^Usage: /model <name>\. Available: (.+?)(?:, or a full model ID)?\.?$")

# The same reply carries the name the default resolves to, which `ModelReadout`
# reads at runtime and `ModelReadoutTests` pins by hand. Nothing generated comes
# off this line — it is per-machine — so the probe prints it to be read against
# those tests, and says so if the shape it is parsed out of has moved.
CURRENT = "Current model: "

# Sending no flag already means this, and two menu entries that do the same
# thing is one too many.
SAME_AS_NO_FLAG = "default"

TEMPLATE = '''import Foundation

/// The names `--model` takes, read off the CLI by
/// `Scripts/model-alias-probe.py` — `claude -p "/model"` prints them under
/// `Available:`. Recorded against **CLI v{version}**; re-run the probe when the
/// CLI moves and the list will move with it.
///
/// The CLI takes a full model id as well, so this says what to offer rather than
/// what to allow — a name that falls off the list still dispatches. `default` is
/// not in here: sending no flag already means that.
public enum ModelAliases {{

    public static let version = "{version}"

    public static let all: [String] = [
{entries}
    ]
}}
'''


def ask(workdir):
    """What the CLI says when /model is given nothing to set."""
    try:
        # DEVNULL because `claude -p` appends piped stdin to the prompt: run
        # from anything that hands the probe a pipe — the sweep's own probe
        # list, until it was fixed — this asked for a model named after that
        # text and came back `Model '…' not found`.
        done = subprocess.run([bundled_cli(), "-p", "/model"], cwd=workdir,
                              stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        sys.exit("claude -p '/model' did not answer inside three minutes")

    if done.returncode != 0:
        sys.exit(f"claude exited {done.returncode}: {done.stderr.strip() or done.stdout.strip()}")
    return done.stdout


def aliases(output):
    for line in output.splitlines():
        found = AVAILABLE.match(line.strip())
        if not found:
            continue
        names = [name.strip() for name in found.group(1).split(",")]
        return [name for name in names if name and name != SAME_AS_NO_FLAG]
    return []


def current(output):
    for line in output.splitlines():
        if line.startswith(CURRENT):
            return line
    return None


def version():
    # Same reason as above: a probe that shells out reads its own arguments,
    # never whoever ran it.
    out = subprocess.run([bundled_cli(), "--version"], stdin=subprocess.DEVNULL,
                         capture_output=True, text=True).stdout
    return out.strip().split(" ")[0] or "unknown"


def main():
    workdir = tempfile.mkdtemp(prefix="model-probe-")
    output = ask(workdir)

    names = aliases(output)
    if not names:
        # Better to keep the list that is there than to replace it with nothing.
        sys.exit("no Available: line in the reply — has /model changed?\n\n" + output)

    said = current(output)
    if not said:
        sys.exit(f"no '{CURRENT}' line in the reply — ModelReadout reads that "
                 f"one, so it has moved too\n\n" + output)

    found = version()
    print(f"{len(names)} model names from CLI v{found}")
    for name in names:
        print(f"  {name}")
    print(f"\ndefault, for ModelReadoutTests to be read against:\n  {said}")

    if "--dry-run" in sys.argv:
        return

    entries = "\n".join(f'        "{name}",' for name in names)
    path = os.path.normpath(OUT)
    with open(path, "w") as handle:
        handle.write(TEMPLATE.format(version=found, entries=entries))
    print("wrote", path)


if __name__ == "__main__":
    main()
