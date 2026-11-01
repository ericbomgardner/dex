#!/usr/bin/env python3
"""Says whether a hosted row can still read its own title and second line.

A CLI session is handed both by `claude agents --json` — the title as `name`, the
work as a job file. A hosted one is handed neither: the host reports state, not
content, and writes no job file at all. Both are read off the transcript instead,
and both readings turn on things the CLI is free to change.

Three of them, and each fails quietly rather than loudly.

**The title is a record of its own.** `{"type":"ai-title","aiTitle":"…"}`, written
a second or two after the first prompt. Rename the type or the field and every
hosted row goes back to saying its folder name, with nothing on screen to say the
reading broke.

**It is rewritten rather than appended to.** The newest one is the session's
current name — a rename lands here too — which is why the app takes the last and
not the first. If the CLI ever stopped reasserting it, the last one would sit
where the session was named and scroll out of the window on a long run. So this
measures how far back the newest one is: the app reads 256k from the end, and a
title further back than that is one it will not find. Nothing about that failure
is visible either, since the index keeps the last title it saw.

**What counts as said.** The row shows the newest message from either side, and a
tool call and the result answering it are records of their own. Read either as
something said and the row shows a diff or a stack trace where the conversation
should be — so this prints the line the row would draw, to be read against what
the app shows.

Nothing is written. The transcripts it reads are your own sessions', so it
reports the version that wrote them rather than the one on your PATH.

Usage:  python3 Scripts/session-digest-probe.py [--projects DIR] [--files N]
"""

import argparse, glob, json, os, re, sys

WINDOW = 256_000  # SessionDigestReader.windows[0]
LIMIT = 240  # TranscriptRecord.saidText


def cleaned(text):
    """The machinery `TranscriptText.cleaned` takes back out, roughly."""
    lead = "The user sent a new message while you were working:"
    reminder = re.search(r"<system-reminder>(.*?)</system-reminder>", text, re.S)
    if reminder:
        body = reminder.group(1).strip()
        kept = body[len(lead):] if body.startswith(lead) else ""
        note = kept.find("This is how Claude Code surfaces messages")
        text = (kept[:note] if note >= 0 else kept).strip()
    for tag in ("task-notification", "usage", "local-command-stdout", "command-message"):
        text = re.sub(rf"<{tag}>.*?</{tag}>", "", text, flags=re.S)
    return " ".join(text.split())


def blocks_of(record):
    content = (record.get("message") or {}).get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return content if isinstance(content, list) else []


def said(record):
    """The prose of a turn, or None where the turn was machinery."""
    texts = [b.get("text", "") for b in blocks_of(record) if b.get("type") == "text"]
    if not texts:
        return None
    folded = cleaned("\n".join(texts))
    return folded[:LIMIT] if folded else None


def spoken(record):
    """What this record contributes as a message, or nothing."""
    if record.get("isSidechain") or record.get("isMeta"):
        return None
    if record.get("type") not in ("user", "assistant"):
        return None
    return said(record)


def walk(path):
    """The newest title, how far back it was, and the newest thing said."""
    size = os.path.getsize(path)
    title = title_at = line = version = None
    offset = 0
    with open(path, "rb") as lines:
        for raw in lines:
            start = offset
            offset += len(raw)
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            version = record.get("version") or version
            if record.get("aiTitle"):
                title, title_at = record["aiTitle"], start
            found = spoken(record)
            if found:
                line = found
    back = size - title_at if title_at is not None else None
    return title, back, line, version, size


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    parser.add_argument("--files", type=int, default=40)
    args = parser.parse_args()

    transcripts = sorted(
        glob.glob(os.path.join(args.projects, "*", "*.jsonl")),
        key=os.path.getmtime,
        reverse=True,
    )[: args.files]
    if not transcripts:
        print(f"no transcripts under {args.projects}")
        return 2

    titled = []
    for path in transcripts:
        title, back, line, version, size = walk(path)
        if title:
            titled.append((path, title, back, line, version, size))

    print(f"walked {len(transcripts)} transcripts, {len(titled)} carried a title")
    if not titled:
        print(
            "  no `ai-title` record in any of them — either the CLI stopped writing\n"
            "  one or these sessions are older than it. Start a session and retry;\n"
            "  if it still finds none, the reading is gone and hosted rows are back\n"
            "  to their folder names."
        )
        return 1

    ok = True
    worst = max(titled, key=lambda found: found[2])
    for path, title, back, line, version, size in titled[:5]:
        print(f"\n  {os.path.basename(path)}  ({version or 'version unrecorded'})")
        print(f"    title   {title!r}  ({back} bytes from the end of {size})")
        print(f"    second  {line!r}")
        if line is None:
            print("    ^ nothing read as said — the row would fall back to its path")

    print(f"\nfurthest a title sat from the end: {worst[2]} bytes (window is {WINDOW})")
    if worst[2] >= WINDOW:
        print(
            "  past the window. The CLI has stopped reasserting the title as the\n"
            "  session runs, so a long session's row keeps whatever title it read\n"
            "  early and a newly-attached one finds none. Widen\n"
            "  `SessionDigestReader.windows` or read the title on its own path."
        )
        ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
