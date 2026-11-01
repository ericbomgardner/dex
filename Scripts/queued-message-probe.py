#!/usr/bin/env python3
"""What the CLI does with a message sent while the session is working.

It queues it either way, and the two ways it comes back out are written down
differently, so the pane has to read both:

  {"type":"queue-operation","operation":"enqueue","content":"…"}   as it goes in
  {"type":"queue-operation","operation":"dequeue"}                 taken as a turn
  {"type":"queue-operation","operation":"remove","content":"…"}    taken into one

A message sent while the session is *thinking* has nothing to be absorbed into,
so it waits for the turn to end and then becomes an ordinary user turn. One sent
into a running *tool call* is folded into that turn instead: the remove carries
`reason: "absorbed_mid_turn"`, the text comes back as an attachment —

  {"type":"attachment","attachment":{"type":"queued_command","prompt":"…",
                                     "commandMode":"prompt"}}

— and no user turn is ever written for it. Read the second shape as machinery and
a message you sent is answered by the model and never shown to you.

So this drives a throwaway session twice, sending a marked message into each kind
of turn, and refuses a run where either half doesn't hold: no enqueue carrying
what was typed, a message that never left the queue, an absorbed one with no
attachment to stand for it, or an absorbed one that turned up as a turn as well —
that last would mean the pane now shows it twice.

Landing each message in the stretch it was aimed at is the whole reading, and a
run that misses by a few seconds looks exactly like a run that measured
something. So both sends are timed off the transcript, printed, and the run is
refused if either is outside its stretch: the absorbed one has to land after the
Bash call started and before its result, and the deferred one after the turn that
set the session thinking and before whatever ended that thinking — its first tool
call if it made one, otherwise the last thing it said. Runs on 2026-08-21 sent
theirs 48 to 96 seconds *after* the call had finished — an idle session, which is
the third shape — and that recorded "a mid-call message is a plain user turn now"
for three weeks. What put them there: in auto mode nothing asks, so a wait for a
permission prompt sits out the whole call.

The queue also carries what the CLI puts there on its own account, which is why
`commandMode` is read rather than assumed; `origin` is not — `{kind: "human"}` on
v2.1.269, null on most older human messages, `{kind: "peer"}` from another session.

Usage:  python3 Scripts/queued-message-probe.py
Needs:  pip3 install pyte
"""

import os, pty, select, time, fcntl, termios, struct, sys, tempfile, glob, json, re
import datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from claude_cli import bundled_cli, keyed

try:
    import pyte
except ImportError:
    sys.exit("needs pyte: pip3 install pyte")

ROWS, COLS = 40, 100

# Long enough to still be running when the message goes in. Written as a loop
# because a bare `sleep` is blocked in some setups, and a blocked call comes
# straight back — which would leave nothing to send a message into.
TOOL_ASK = ("Run this with the Bash tool, exactly as written, then tell me it "
            "finished: `for i in $(seq 1 25); do date >> /dev/null; sleep 2; done`")
THINK_ASK = ("Without using any tools, write a paragraph about each of the eight "
             "planets, in order, longest first.")

ABSORBED = "QUEUEDPROBEABSORBED please just say ok"
DEFERRED = "QUEUEDPROBEDEFERRED please just say ok"

PATIENCE = 300

# Since CLI v2.1.278 a directory the CLI has never been run in is met with a
# picker before anything else is drawn:
#
#     Quick safety check: Is this a project you created or one you trust? …
#     ❯ No, exit
#       Yes, I trust this folder
#
# The probe works in a fresh mkdtemp, so every run gets it, and the highlight
# starts on the row that quits — so the first thing typed killed the CLI, and
# the run reported "the session never got the tool running", which reads like
# the CLI stopped queueing rather than like it never started.
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
        env, args = keyed(env, "queued-message-probe")
        cli = bundled_cli()

        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(workdir)
            os.execve(cli, ["claude", *args], env)
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

    def say(self, text):
        os.write(self.fd, b"\x1b[200~" + text.encode() + b"\x1b[201~")
        self.pump(0.6)
        os.write(self.fd, b"\r")

    def press(self, key):
        os.write(self.fd, key)
        self.pump(1.5)

    def lines(self):
        return [line.rstrip() for line in self.screen.display]

    def close(self):
        for key in (b"\x1b", b"\x03", b"\x03"):
            try:
                os.write(self.fd, key)
            except OSError:
                break
            self.pump(0.3)
        try:
            os.close(self.fd)
            os.kill(self.pid, 9)
            os.waitpid(self.pid, 0)
        except OSError:
            pass


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


def working(session):
    """The line the CLI keeps while a turn is in flight: a verb it swaps as it
    goes, an ellipsis, and a clock. Nothing pins that wording, and nothing needs
    to: it is only the trigger for the send. What proves the send landed in the
    stretch it was aimed at is read back off the transcript — the leads and gaps
    printed below, each of which refuses a run that drifted."""
    for line in reversed(session.lines()):
        body = line.lstrip()
        if "…" in body and "(" in body and any(c.isdigit() for c in body):
            return body
    return ""


def wait_until(session, holds, patience=PATIENCE):
    waited = 0
    while waited < patience:
        if holds():
            return True
        session.pump(0.5)
        waited += 0.5
    return False


def screen_has(session, text):
    return text in "\n".join(session.lines())


def session_cwd(path):
    for line in open(path, errors="replace"):
        try:
            where = json.loads(line).get("cwd")
        except ValueError:
            continue
        if where:
            return where
    return None


def records(workdir):
    root = os.path.expanduser("~/.claude/projects")
    wanted = os.path.realpath(workdir)

    # The CLI names the directory after the path it was run in, with every "/"
    # and "_" written as "-" — and mkdtemp is entitled to an underscore, so the
    # name on disk is not always the name we asked for.
    slug = "-" + wanted.strip("/").replace("/", "-").replace("_", "-")
    found = glob.glob(f"{root}/{slug}/*.jsonl") or [
        path for path in glob.glob(f"{root}/*queued-message-probe*/*.jsonl")
        if session_cwd(path) == wanted
    ]
    if not found:
        sys.exit("no transcript was written — the session never started")

    newest = sorted(found, key=os.path.getmtime)[-1]
    print(f"transcript: {newest}")
    out = []
    for line in open(newest, errors="replace"):
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


# A message is typed in one piece, through bracketed paste, and the CLI records
# it wrapped: <pasted_content id="2709">\n…\n</pasted_content id="2709">, on the
# enqueue, on the remove and in the attachment's prompt alike. Peeled rather than
# matched loosely: "the marker is in there somewhere" would also pass on a record
# that merely quoted the message, and what is being pinned is that the text
# itself rides on those records.
PASTED = re.compile(r'^<pasted_content id="[^"]*">\n(.*)\n</pasted_content id="[^"]*">$',
                    re.S)


def typed(text):
    """What was typed, out of whatever wrapper the CLI wrote it down in."""
    if not isinstance(text, str):
        return text
    found = PASTED.match(text.strip())
    return (found.group(1) if found else text).strip()


def queue_ops(rows, operation, message=None):
    return [r for r in rows
            if r.get("type") == "queue-operation"
            and r.get("operation") == operation
            and (message is None or typed(r.get("content")) == message)]


def attachments(rows, message):
    out = []
    for r in rows:
        if r.get("type") != "attachment":
            continue
        held = r.get("attachment") or {}
        if held.get("type") == "queued_command" and typed(held.get("prompt")) == message:
            out.append(held)
    return out


def turns(rows, message):
    out = []
    for r in rows:
        if r.get("type") != "user" or r.get("isMeta") or r.get("isSidechain"):
            continue
        content = (r.get("message") or {}).get("content")
        text = content if isinstance(content, str) else " ".join(
            b.get("text", "") for b in (content or []) if isinstance(b, dict))
        if message in text:
            out.append(r)
    return out


def when(record):
    stamp = record.get("timestamp")
    try:
        return datetime.datetime.fromisoformat((stamp or "").replace("Z", "+00:00"))
    except ValueError:
        return None


def first_mention(rows, message):
    """When the CLI first wrote the message down, wherever that was: the queue
    if it went through one, the turn itself if the session was idle."""
    for r in rows:
        if message in json.dumps(r):
            return when(r)
    return None


def call_span(rows):
    """When the call the message was meant to land inside started and ended,
    matched by id off the command itself — a turn that reaches for some other
    tool first, or runs a quick shell command ahead of this one, would otherwise
    stand in for it and the gap would read off the wrong call."""
    wanted, started = None, None
    for r in rows:
        if wanted is None and r.get("type") == "assistant":
            for b in (r.get("message") or {}).get("content") or []:
                if (b.get("type") == "tool_use" and b.get("name") == "Bash"
                        and "seq 1 25" in str((b.get("input") or {}).get("command"))):
                    wanted, started = b.get("id"), when(r)
        elif wanted is not None and r.get("type") == "user":
            content = (r.get("message") or {}).get("content")
            if isinstance(content, list) and any(
                    isinstance(b, dict) and b.get("type") == "tool_result"
                    and b.get("tool_use_id") == wanted for b in content):
                return started, when(r)
    return started, None


def think_span(rows):
    """The stretch where the session had nothing to absorb a message into: from
    the turn that set it thinking to whatever ended that — its first tool call if
    it made one, otherwise the last thing it said, after which it is idle. A send
    outside that window is one of the other two shapes wearing this one's name."""
    begin = next((index for index, r in enumerate(rows)
                  if r.get("type") == "user" and not r.get("isMeta")
                  and THINK_ASK in json.dumps(r.get("message") or {})), None)
    if begin is None:
        return None, None

    started, said = when(rows[begin]), None
    for r in rows[begin + 1:]:
        blocks = (r.get("message") or {}).get("content") or []
        blocks = [b for b in blocks if isinstance(b, dict)]
        if r.get("type") == "assistant":
            if any(b.get("type") == "tool_use" for b in blocks):
                return started, when(r)
            if any(b.get("type") == "text" and b.get("text", "").strip() for b in blocks):
                said = when(r)
        elif (r.get("type") == "user" and not r.get("isMeta")
                and not any(b.get("type") == "tool_result" for b in blocks)):
            break
    return started, said


def main():
    workdir = tempfile.mkdtemp(prefix="queued-message-probe-")
    session = Session(workdir)
    version = "unknown"
    try:
        session.pump(12)
        accept_trust(session)
        # Off the banner, while it is still the newest thing on the screen.
        for line in session.lines():
            if "Claude Code v" in line:
                version = line.split("Claude Code v")[1].split(" ")[0].strip("─ ")

        # Into a tool call, which the session absorbs the message into.
        session.say(TOOL_ASK)

        # In auto mode nothing asks, so waiting for the prompt on its own waits
        # out the whole call and leaves the message landing on an idle session.
        # `seq 1 25` is on screen from the moment the ask is echoed back, so the
        # gate reads the CLI's own tool line, which appears only once it calls.
        #
        # That line is no longer "Bash(…)". v2.1.278 draws a running shell call
        # as a summary the model writes, with the command echoed beneath it, and
        # collapses the pair to "Ran 1 shell command" the moment it is done:
        #
        #     ⏺ Looping 25 times with 2-second sleeps · 3s
        #       ⎿  $ for i in $(seq 1 25); do date >> /dev/null; sleep 2; done (5s)
        #
        # So the gate reads the echoed command, not the summary — the summary is
        # the model's own words and different every run — anchored to the "$ "
        # the echo carries, since the ask quotes the same command back at the top
        # of the screen and would otherwise match before the call had started.
        #
        # v2.1.280 draws it the old way again, and either may come back:
        #
        #     ⏺ Bash(for i in $(seq 1 25); do date >> /dev/null; sleep 2; done)
        #       ⎿  Running… (34s · timeout 2m)
        #
        # "Bash(" stays on screen once the call is done, and the working line
        # outlives it by a beat, so this shape needs the "Running…" under it.
        # Still only the trigger: what proves the send landed inside the call is
        # the transcript's leads below, which refuse a run that missed.
        def running():
            lines = session.lines()
            echoed = any("$ for i in $(seq 1 25)" in line for line in lines)
            called = any(line.lstrip().startswith("⏺ Bash(for i in $(seq 1 25)")
                         or line.lstrip().startswith("Bash(for i in $(seq 1 25)")
                         for line in lines)
            ticking = any(line.lstrip().startswith("⎿") and "Running…" in line
                          for line in lines)
            return (echoed or (called and ticking)) and bool(working(session))

        if not wait_until(session, lambda: running() or screen_has(session, "Do you want"),
                          patience=90):
            sys.exit("the session never got the tool running — nothing to send into")
        if screen_has(session, "Do you want"):
            session.press(b"2")
            if not wait_until(session, running, patience=90):
                sys.exit("the session never got the tool running — nothing to send into")
        session.pump(6)
        session.say(ABSORBED)
        session.pump(2)
        # Said, not asserted. The queue is a thing the transcript records, and
        # that is what the app reads and what this checks below; how the TUI
        # words it on screen is neither, and pinning the wording made a probe
        # that failed on a rename of something nothing here depends on.
        if not screen_has(session, "queued messages"):
            print("  note: the screen didn't say 'queued messages' — wording may "
                  "have changed; the records below are what decides")
        wait_until(session, lambda: not working(session))
        session.pump(10)

        # Into a think, which has nothing to absorb it into.
        session.say(THINK_ASK)
        if not wait_until(session, lambda: bool(working(session)), patience=90):
            sys.exit("the session never started the second turn")
        session.pump(4)
        session.say(DEFERRED)
        wait_until(session, lambda: not working(session))
        session.pump(20)
    finally:
        session.close()

    rows = records(workdir)
    print(f"CLI: v{version}\n")

    problems = []

    # A message sent into a running tool call is taken into that turn. It goes in
    # through the queue, comes back out as an attachment, and is written as a turn
    # nowhere — which is the shape `TranscriptDocument.absorbedMessage` reads, and
    # all that stands between a message you sent and one you never see answered.
    held = attachments(rows, ABSORBED)
    absorbed_out = [r for r in queue_ops(rows, "remove", ABSORBED)
                    if r.get("reason") == "absorbed_mid_turn"]
    if not queue_ops(rows, "enqueue", ABSORBED):
        problems.append(
            "the absorbed message was never enqueued with its text beside it")
    if not held:
        problems.append(
            "the absorbed message was taken into the turn with no queued_command "
            "attachment to stand for it — the pane has nothing left to show")
    elif not any(h.get("commandMode") == "prompt" for h in held):
        problems.append(
            "the absorbed message's attachment is no longer commandMode 'prompt' "
            f"but {sorted(str(h.get('commandMode')) for h in held)} — that field is "
            "the only thing telling a typed message from the CLI's own")
    if not absorbed_out:
        problems.append(
            "the absorbed message never left the queue as absorbed_mid_turn")
    if turns(rows, ABSORBED):
        problems.append(
            "the absorbed message was written as a user turn as well as an "
            "attachment — the pane will show it twice")

    # The deferred one still queues, and its text still rides on the enqueue,
    # which is the only place the composer can read a waiting message from.
    if not queue_ops(rows, "enqueue", DEFERRED):
        problems.append(
            "the deferred message was never enqueued with its text beside it — "
            "the pane has nothing to show while it waits")
    if not (queue_ops(rows, "remove", DEFERRED) or queue_ops(rows, "dequeue")):
        problems.append("the deferred message never left the queue")
    if not turns(rows, DEFERRED):
        problems.append("the deferred message never became a turn of its own")

    (started_at, result_at), sent_at = call_span(rows), first_mention(rows, ABSORBED)
    gap = (sent_at - result_at).total_seconds() if result_at and sent_at else None
    lead = (sent_at - started_at).total_seconds() if started_at and sent_at else None

    (think_at, quiet_at), waited_at = think_span(rows), first_mention(rows, DEFERRED)
    into = (waited_at - think_at).total_seconds() if think_at and waited_at else None
    left = (waited_at - quiet_at).total_seconds() if quiet_at and waited_at else None

    print("what the run found")
    print(f"  enqueued:          {len(queue_ops(rows, 'enqueue'))}")
    print(f"  dequeued:          {len(queue_ops(rows, 'dequeue'))}")
    print(f"  removed:           {len(queue_ops(rows, 'remove'))}")
    print(f"  absorbed message:  {len(held)} attachment(s), "
          f"{len(turns(rows, ABSORBED))} turn(s), "
          f"{len(absorbed_out)} absorbed_mid_turn")
    print(f"  deferred message:  {len(attachments(rows, DEFERRED))} attachment(s), "
          f"{len(turns(rows, DEFERRED))} turn(s)")
    print(f"  send vs call:      {lead:+.0f}s" if lead is not None
          else "  send vs call:      not written down")
    print(f"  send vs result:    {gap:+.0f}s" if gap is not None
          else "  send vs result:    not written down")
    print(f"  send vs turn:      {into:+.0f}s into the thinking, {left:+.0f}s "
          "from the end of it" if into is not None and left is not None
          else "  send vs turn:      not written down")

    # Inside the call is the whole reading. After it is a send to an idle session,
    # before it is a send to a thinking one, and both pass assertions they were
    # never asked.
    if gap is None or gap >= 0:
        sys.exit("\nthe absorbed message landed after the call had finished — this "
                 "run measured the idle shape, not the absorbed one, and says "
                 "nothing either way")
    if lead is None or lead <= 0:
        sys.exit("\nthe absorbed message landed before the call had started — this "
                 "run measured the thinking shape, not the absorbed one, and says "
                 "nothing either way")

    # And the deferred half the same way round: a send that lands in a tool call,
    # or after the turn had finished, is one of the other two shapes.
    if into is None or left is None:
        sys.exit("\nthe deferred message's stretch isn't in the transcript — no "
                 "thinking turn to have landed inside, so this run says nothing")
    if into <= 0 or left >= 0:
        sys.exit("\nthe deferred message landed outside the thinking stretch — "
                 "before the turn began, inside a tool call it made, or after it "
                 "had finished speaking. Either way this run measured one of the "
                 "other two shapes and says nothing about the deferred one")

    if problems:
        print("\nthe CLI has moved:")
        for problem in problems:
            print(f"  - {problem}")
        sys.exit(1)

    print("\nboth shapes hold. TranscriptDocumentTests pins them.")
    print("note: the `queued_command` attachment is the only record of a message")
    print("      typed into a running call, so TranscriptDocument.absorbedMessage")
    print("      is load-bearing for commandMode 'prompt' as well as for its")
    print("      'task-notification' sibling.")


main()
