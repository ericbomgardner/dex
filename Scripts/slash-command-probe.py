#!/usr/bin/env python3
"""Reads the CLI's own list of built-in slash commands and writes it into the app.

The CLI has no way to print its commands, so this drives a real session: /help,
over to the "Commands" tab, and down the list until it stops giving up new ones.
What comes back is what that CLI version has, descriptions and all.

Custom commands are not in here — the app reads those off disk at runtime, per
user and per project.

Harvesting is the part that fails quietly. Any line shaped `  /name` reads as a
command, so a half-drawn panel, an autocomplete popup over it, or a trust prompt
eating the /help altogether would each write a *shorter* file and say nothing.
Three things stand against that, and none of them is a sleep:

  * the Commands tab prints its own header — "Browse default commands", which it
    keeps at the top through the whole scroll — and nothing is harvested until
    that is on screen, or once it leaves;
  * a set of names the CLI has always shipped has to come back, since one of
    those missing is a half-read screen rather than a smaller CLI;
  * a list shorter than 90% of the one already on disk is refused outright. If
    the CLI really did drop that many, say so with --shrink.

Usage:  python3 Scripts/slash-command-probe.py [--dry-run] [--shrink]
Needs:  pip3 install pyte
"""

import os, pty, select, time, fcntl, termios, struct, shutil, sys, re, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from claude_cli import bundled_cli, on_login

try:
    import pyte
except ImportError:
    sys.exit("needs pyte: pip3 install pyte")

ROWS, COLS = 45, 160
OUT = os.path.join(os.path.dirname(__file__), "..",
                   "Sources", "DexCore", "Composer", "BuiltInCommands.swift")

# The row under the cursor wears a marker, and the top and bottom of the list
# wear a scroll arrow; the name is the same either way.
NAME = re.compile(r"^\s{2,}(?:[❯>↑↓]\s+)?(/[a-zA-Z0-9][a-zA-Z0-9:_-]*)\s*$")

# The list only scrolls once the cursor has walked to the foot of the page, so
# giving up needs to take longer than a page is deep.
PATIENCE = 30

# The Commands tab's own header, and the one thing on screen that says the lines
# being read are the CLI's list. It stays put while the list scrolls under it.
PANEL = "Browse default commands"

# Names that have shipped for as long as this probe has run. One of them absent
# is a screen read too early, not a CLI that dropped it.
SENTINELS = ("help", "model", "compact", "clear", "exit")

# How much of the list on disk a rewrite has to still find.
FLOOR = 0.9

# Since CLI v2.1.278 a directory the CLI has never been run in is met with a
# picker before anything else is drawn:
#
#     Quick safety check: Is this a project you created or one you trust? …
#     ❯ No, exit
#       Yes, I trust this folder
#
# The probe works in a fresh mkdtemp, so every run gets it, and the highlight
# starts on the row that quits — so the first keystroke sent into it killed the
# CLI, and what came back was an OSError on a dead pty rather than anything
# about slash commands.
#
# Answered on the screen rather than pre-trusted by writing the CLI's own
# `hasTrustDialogAccepted` bookkeeping into ~/.claude.json: that key is
# undocumented, and a probe that forges the CLI's config to get past the CLI's
# own prompt stops noticing the day either one moves.
TRUST_PROMPT = "trust this folder"
TRUST_YES = "Yes, I trust this folder"
HIGHLIGHT = "❯"
# What the CLI draws instead when the directory is already trusted.
BANNER = "Claude Code v"


class Session:
    def __init__(self, workdir):
        self.screen = pyte.Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith("CLAUDE") and k != "CLAUDECODE"}
        env.update(TERM="xterm-256color", COLORTERM="truecolor")
        env = on_login(env, "slash-command-probe")
        cli = bundled_cli()

        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(workdir)
            os.execve(cli, ["claude"], env)
        os.set_blocking(self.fd, False)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.stream.feed(chunk)

    def write(self, data, settle=0.4):
        os.write(self.fd, data)
        self.pump(settle)

    def lines(self):
        return [line.rstrip() for line in self.screen.display]

    def shows(self, text):
        return any(text in line for line in self.lines())

    def wait_for(self, text, patience=20):
        end = time.time() + patience
        while time.time() < end:
            if self.shows(text):
                return True
            self.pump(0.25)
        return self.shows(text)

    def close(self):
        self.write(b"\x1b", 0.3)
        self.write(b"\x03", 0.3)
        self.write(b"\x03", 0.3)
        os.close(self.fd)
        os.kill(self.pid, 9)
        os.waitpid(self.pid, 0)


def accept_trust(session, patience=20):
    """Answer the first-run trust picker, if that is what the CLI drew.

    Waits for whichever turns up first, the banner or the picker, and leaves a
    session that was already trusted alone. The Yes row is found by its words
    and the highlight is checked rather than counted, since which row the picker
    opens on is the CLI's to change — and it opens on the one that quits."""
    screen = lambda: "\n".join(session.lines())

    end = time.time() + patience
    while time.time() < end:
        if BANNER in screen() or TRUST_PROMPT in screen().lower():
            break
        session.pump(0.25)
    if TRUST_PROMPT not in screen().lower():
        return False

    for _ in range(6):
        row = next((line for line in session.lines() if TRUST_YES in line), None)
        if row is None or row.lstrip().startswith(HIGHLIGHT):
            break
        os.write(session.fd, b"\x1b[B")
        session.pump(0.3)

    row = next((line for line in session.lines() if TRUST_YES in line), "")
    if not row.lstrip().startswith(HIGHLIGHT):
        sys.exit(f"the trust picker is on screen but '{TRUST_YES}' never took "
                 f"the '{HIGHLIGHT}' highlight — the picker has been reworded or "
                 "rearranged, and pressing Enter now would answer whatever is "
                 "highlighted instead.\n" + screen())

    os.write(session.fd, b"\r")
    end = time.time() + 15
    while time.time() < end:
        session.pump(0.25)
        if TRUST_PROMPT not in screen().lower():
            session.pump(1.0)
            return True
    sys.exit("the trust picker was answered and did not clear inside 15s — the "
             "CLI is waiting on something this probe doesn't know about.\n"
             + screen())


def harvest(session):
    """Every command on screen now, as (name, description) in the order shown."""
    found = []
    lines = session.lines()
    for index, line in enumerate(lines):
        match = NAME.match(line)
        if not match:
            continue
        description = lines[index + 1].strip() if index + 1 < len(lines) else ""
        if description.startswith("/"):
            description = ""
        found.append((match.group(1), description))
    return found


def collect(session):
    """Walk the list until it stops giving up new names, reading each screen the
    panel is still drawing. Returns the commands and the number of screens that
    gave up one — a list this long takes dozens, and a handful is a list cut off."""
    commands = {}
    order = []
    barren = 0
    screens = 0

    while barren < PATIENCE:
        if not session.shows(PANEL):
            sys.exit(f"'{PANEL}' left the screen {len(order)} commands in — "
                     "something took the panel over mid-harvest, so this is part "
                     "of a list and there is no way to tell which part.\n"
                     + "\n".join(session.lines()))
        fresh = 0
        for name, description in harvest(session):
            if name in commands:
                # A description cut off by the width fills in on a later pass.
                if len(description) > len(commands[name]):
                    commands[name] = description
                continue
            commands[name] = description
            order.append(name)
            fresh += 1

        screens += 1 if fresh else 0
        barren = 0 if fresh else barren + 1
        session.write(b"\x1b[B", 0.12)

    return [(name, commands[name]) for name in order], screens


def swift(commands, version):
    rows = "\n".join(
        '        Command(name: "%s", summary: "%s"),' % (name[1:], escape(tidy(summary)))
        for name, summary in commands
    )
    return f'''import Foundation

/// The commands the CLI ships with, read off its own help by
/// `Scripts/slash-command-probe.py` — it has no way to print them. Recorded
/// against **CLI v{version}**; re-run the probe when the CLI moves and the list
/// will move with it.
///
/// Custom commands are not in here. Those come off disk, per user and per
/// project, in ``SlashCommands``.
public enum BuiltInCommands {{

    public static let version = "{version}"

    public static let all: [Command] = [
{rows}
    ]
}}
'''


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"')


def tidy(summary):
    """A summary wider than the screen comes back cut. Better to end on a word."""
    if not summary.endswith("…"):
        return summary
    trimmed = summary[:-1].rstrip()
    head, _, tail = trimmed.rpartition(" ")
    return (head if head and not tail.endswith((".", ",", ";")) else trimmed).rstrip(" ,;")


def version():
    import subprocess
    out = subprocess.run([bundled_cli(), "--version"], capture_output=True, text=True).stdout
    return out.strip().split(" ")[0] or "unknown"


def on_disk():
    """How long the list already is — the floor a rewrite has to clear."""
    try:
        with open(os.path.normpath(OUT)) as handle:
            return handle.read().count("Command(name:")
    except OSError:
        return 0


def main():
    workdir = tempfile.mkdtemp(prefix="slash-probe-")
    session = Session(workdir)
    try:
        session.pump(10)
        accept_trust(session)
        session.write(b"\x1b[200~/help\x1b[201~", 0.4)
        session.write(b"\r", 3.0)

        # General → Commands
        session.write(b"\t", 1.5)
        if not session.wait_for(PANEL):
            sys.exit(f"the Commands tab never printed '{PANEL}' — /help was eaten "
                     "by something else, or the panel has been renamed. Reading "
                     "this screen would harvest whatever happened to look like a "
                     "command.\n" + "\n".join(session.lines()))

        commands, screens = collect(session)
    finally:
        session.close()
        shutil.rmtree(workdir, ignore_errors=True)

    if not commands:
        sys.exit("no commands found")

    commands.sort()
    disk = on_disk()
    print(f"{len(commands)} commands from CLI v{version()}, harvested off "
          f"{screens} screen(s) of the panel; {disk} on disk")
    for name, summary in commands:
        print(f"  {name:<28} {summary[:60]}")

    missing = [name for name in SENTINELS
               if name not in {found[1:] for found, _ in commands}]
    if missing:
        sys.exit("\nthe harvest is missing commands the CLI has always shipped: "
                 + ", ".join("/" + name for name in missing)
                 + " — that is a screen read too early, not a shorter CLI")

    floor = int(disk * FLOOR)
    if len(commands) < floor and "--shrink" not in sys.argv:
        sys.exit(f"\n{len(commands)} commands is under the floor of {floor} "
                 f"({FLOOR:.0%} of the {disk} on disk) — refusing to write a list "
                 "this much shorter, since a half-read screen looks exactly like "
                 "this. Pass --shrink if the CLI really did drop them.")

    if "--dry-run" in sys.argv:
        return

    path = os.path.normpath(OUT)
    with open(path, "w") as handle:
        handle.write(swift(commands, version()))
    print("wrote", path)


if __name__ == "__main__":
    main()
