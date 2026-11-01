#!/usr/bin/env python3
"""Says whether a subagent still reports what the pane prints.

There are two ways a subagent comes back, and the pane reads both.

A foreground agent's result carries the CLI's own account of the run beside it —
`totalToolUseCount`, `totalTokens`, `totalDurationMs`. A background one's result
is only a receipt (`status: "async_launched"`) written the moment it is launched;
word that the work is over arrives later, a `<task-notification>` naming the call
it belongs to, with the same three counts in a `<usage>` block inside it.

That word comes through one of two doors, and the pane has to watch both. An idle
session is handed it as a turn of its own. A session busy with a tool call
absorbs it into the turn it is already running — an `attachment` under
`commandMode: "task-notification"`, and no turn is written at all. Watch only the
first door and roughly one agent in five never comes back: its row keeps a clock
running for the rest of the conversation.

Rename any of that and the pane quietly stops saying anything about the agent, or
worse, reads the receipt as the end of the work. So this walks the newest
transcripts for one of each, says which door it came through, and writes out the
line the pane would make of it, to be read against what the terminal showed.

Nothing is written. The transcripts it reads are your own sessions', so it needs
one that ran a subagent — and it reports the version that wrote that transcript
rather than the one on your PATH, since they are only the same if you have run an
agent since the last CLI update.

Usage:  python3 Scripts/subagent-totals-probe.py [--projects DIR] [--files N]
"""

import argparse, glob, json, os, re, sys

WANTED = ["totalToolUseCount", "totalTokens", "totalDurationMs"]
COUNTS = ["tool_uses", "subagent_tokens", "duration_ms"]
DELEGATION = {"Task", "Agent"}


def tag(name, text):
    found = re.search(rf"<{name}>(.*?)</{name}>", text, re.S)
    return found.group(1).strip() if found else None


def walk(path):
    """This transcript's finished Task results and its agent notices.

    A notice is kept with the door it came through, since the pane reads them
    from different records and either one can go quiet on its own.
    """
    delegated, results, notices = set(), [], []
    interim = {}

    def notice(text, version, door):
        # A prompt that only mentions the tag is prose about it, and a watcher's
        # event names no call and carries no tally; either, read as the newest
        # agent, reports the surface moved when nothing did.
        if not text.lstrip().startswith("<task-notification>"):
            return
        if (tag("summary", text) or "").startswith("Monitor event:"):
            return
        # Since CLI v2.1.299 an agent that backgrounds its own work notifies
        # twice: an interim notice naming the call, then the final one naming
        # only the task. The pane joins them by the task id, and so does this;
        # a task-only notice with no interim one before it is still drift.
        call, task = tag("tool-use-id", text), tag("task-id", text)
        if call and task:
            if "interim" in (tag("note", text) or ""):
                interim[task] = call
            else:
                interim.pop(task, None)
        elif task in interim:
            call = f"{interim.pop(task)}, by its task id after an interim notice"
        notices.append((text, version, door, call))

    with open(path, errors="replace") as lines:
        for line in lines:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            version = record.get("version") or "version unrecorded"

            # The CLI hands a notice in as a user turn. An assistant one that
            # mentions the tag is prose *about* the machinery — a session that
            # was reading its own transcript, say — and reading it as the real
            # thing reports the surface moved when nothing did. Cost a day:
            # only this session's file had one, and it was the newest. Since
            # CLI v2.1.300 an `api-request-blob` repeats it unversioned, after it.
            injected = (record.get("type") == "user"
                        and (record.get("message") or {}).get("role") == "user")

            absorbed = record.get("attachment")
            absorbed = absorbed if isinstance(absorbed, dict) else {}
            if absorbed.get("commandMode") == "task-notification":
                prompt = str(absorbed.get("prompt") or "")
                if "<task-notification>" in prompt:
                    notice(prompt, version, "absorbed into the running turn")

            for block in (record.get("message") or {}).get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use" and block.get("name") in DELEGATION:
                    delegated.add(block.get("id"))
                elif block.get("type") == "tool_result" and block.get("tool_use_id") in delegated:
                    beside = record.get("toolUseResult")
                    beside = beside if isinstance(beside, dict) else {}
                    # A receipt is not a result — the agent is still working.
                    if beside.get("status") == "async_launched" or beside.get("isAsync"):
                        continue
                    # Nor is nothing at all. An agent whose run was cut off — a
                    # host killed, a session interrupted — comes back with no
                    # keys beside it, which is not the same as coming back with
                    # keys that have been renamed, and only the second is drift.
                    # Read as drift it fails the probe on the newest bad sample
                    # and says a surface moved that nobody touched.
                    if beside:
                        results.append((beside, version))
                elif (block.get("type") == "text" and injected
                      and "<task-notification>" in str(block.get("text"))):
                    notice(block["text"], version, "a turn of its own")
            content = (record.get("message") or {}).get("content")
            if injected and isinstance(content, str) and "<task-notification>" in content:
                notice(content, version, "a turn of its own")
    return results, notices


def elapsed(milliseconds):
    """`Format.elapsed`, to be compared with the terminal by eye."""
    whole = round(max(0, milliseconds) / 1000)
    if whole < 60:
        return f"{whole}s"
    return f"{whole // 60}m {whole % 60}s" if whole % 60 else f"{whole // 60}m"


def compact(count):
    """`Format.compact`."""
    if count < 1000:
        return str(count)
    thousands = round(count / 1000, 1)
    if thousands < 1000:
        return f"{thousands:g}k"
    return f"{round(thousands / 1000, 1):g}M"


def summary(uses, tokens, milliseconds):
    """`SubagentTotals.summary` — what the pane puts at the end of the row."""
    return " · ".join([
        "1 tool use" if uses == 1 else f"{uses} tool uses",
        f"{compact(tokens)} tokens",
        elapsed(milliseconds),
    ])


def report_result(result, version):
    print(f"  a foreground agent's result — CLI {version}")
    print(f"    keys beside it: {', '.join(sorted(result)) or '(none)'}")
    missing = [key for key in WANTED if key not in result]
    if missing:
        print(f"    MOVED — nothing to print without: {', '.join(missing)}")
        return False
    print("    the pane prints: " + summary(*(result[key] for key in WANTED)))
    return True


def report_notice(notice, version, door, call):
    print(f"  a background agent's notice, {door} — CLI {version}")
    print(f"    names the call: {call or 'NO — MOVED'}")
    counts = [tag(name, notice) for name in COUNTS]
    if not all(counts):
        print(f"    no tally in it ({', '.join(COUNTS)}) — the pane falls back to timestamps")
    else:
        print("    the pane prints: " + summary(int(counts[0]), int(counts[1]), float(counts[2])))
    return call is not None


def main():
    home = os.path.expanduser("~/.claude/projects")
    parser = argparse.ArgumentParser()
    parser.add_argument("--projects", default=home, help=f"where transcripts live ({home})")
    parser.add_argument("--files", type=int, default=40, help="how many to walk back through")
    args = parser.parse_args()

    transcripts = sorted(
        glob.glob(os.path.join(args.projects, "**", "*.jsonl"), recursive=True),
        key=os.path.getmtime,
        reverse=True,
    )[: args.files]

    doors = ["a turn of its own", "absorbed into the running turn"]
    result, found = None, {}
    for path in transcripts:
        results, notices = walk(path)
        result = result or (results[0] if results else None)
        for notice in notices:
            found.setdefault(notice[2], notice)
        if result and len(found) == len(doors):
            break

    if not result and not found:
        print(f"no subagent in the last {args.files} transcripts — run one and retry")
        return 2

    print(f"walked {len(transcripts)} transcripts")
    ok = True
    if result:
        ok &= report_result(*result)
    else:
        print("  no foreground agent came back in these — not checked")
    for door in doors:
        if door in found:
            ok &= report_notice(*found[door])
        else:
            # Not a failure: which door a notice comes through is up to what the
            # session happened to be doing, and only one of them is on offer in
            # any given run.
            print(f"  no background agent reported {door} in these — not checked")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
