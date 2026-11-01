#!/usr/bin/env python3
"""Read Claude Code transcripts and report where the tokens, and the cost, went.

Usage:
    Scripts/maintainer/token-audit.py                    # last 24h, all projects
    Scripts/maintainer/token-audit.py --hours 2
    Scripts/maintainer/token-audit.py --days 7
    Scripts/maintainer/token-audit.py --session <id>     # carry-cost anatomy of one session
    Scripts/maintainer/token-audit.py --long             # sessions worth splitting

Weighted units are dollar-equivalents at list price, used as a common scale
across models -- a Fable token and a Haiku token don't cost the same.
Subagents write their own agent-<id>.jsonl; they are attributed back
to the parent through the sessionId they carry.

Read off Claude Code rather than agreed with it, against CLI v2.1.227 -- re-check
when it moves, since nothing here fails loudly:

  message.usage          input_tokens, output_tokens, cache_read_input_tokens,
                         cache_creation_input_tokens, and cache_creation.{ephemeral_5m,
                         ephemeral_1h}_input_tokens. The 5m/1h split decides whether a
                         write is priced at 1.25x or 2x; absent it, everything is
                         assumed 5m. A rename here silently reports zero.
  message.model          resolved id (claude-opus-5), not the launch alias.
  isSidechain            marks a subagent's own turns. No transcript mixes main and
                         sidechain records -- subagents always get their own file.
  sessionId              on a subagent file this is the PARENT's id, which is the only
                         thing linking the two. Without it subagent spend is orphaned.
  attributionAgent       subagent type name; absent on files written before ~v2.1.22x.

Prices are the published list rates and go stale on their own schedule -- checked
October 2026, when Haiku 5.5 arrived with a second rate past a 100k prompt. They only
need to be right relative to each other.
"""

import argparse
import glob
import json
import os
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

PRICE = {
    "claude-fable-5-1": (10e-6, 50e-6),
    "claude-fable-5": (10e-6, 50e-6),
    "claude-mythos-5-1": (10e-6, 50e-6),
    "claude-mythos-5": (10e-6, 50e-6),
    "claude-opus-5-5": (4e-6, 20e-6),
    "claude-opus-5": (5e-6, 25e-6),
    "claude-opus-4-8": (5e-6, 25e-6),
    "claude-opus-4-7": (5e-6, 25e-6),
    "claude-opus-4-6": (5e-6, 25e-6),
    "claude-opus-4-5": (5e-6, 25e-6),
    "claude-sonnet-5-5": (2e-6, 10e-6),
    "claude-sonnet-5": (2e-6, 10e-6),
    "claude-sonnet-4-6": (3e-6, 15e-6),
    "claude-sonnet-4-5": (3e-6, 15e-6),
    "claude-haiku-5-5": (0.1e-6, 0.5e-6),
    "claude-haiku-4-5": (1e-6, 5e-6),
}

# Past this many prompt tokens, cached reads included, the whole request bills at
# the second pair; the badge's `Rate.longPrompt` reads the same split.
LONG_PROMPT = {"claude-haiku-5-5": (100_000, 0.5e-6, 2.5e-6)}

# Code tokenizes denser than prose; used only for the carry-cost estimate,
# which is reconciled against billed cache reads before it is printed.
CHARS_PER_TOKEN = 3.0


def family(model):
    """A dated id or a width variant prices as its family; a bare prefix priced Opus 5.5 as Opus 5."""
    model = model.split("[", 1)[0]
    head, _, tail = model.rpartition("-")
    return head if len(tail) == 8 and tail.isdigit() else model


def price(model):
    return PRICE.get(family(model))


# Fable 5.1 and Mythos 5.1 read cache at 2.5% of input, Opus 5.5 at 5%; everything else at 10%.
READ_SHARE = {"claude-fable-5-1": 0.025, "claude-mythos-5-1": 0.025, "claude-opus-5-5": 0.05}


def read_share(model):
    return READ_SHARE.get(family(model), 0.1)


def units(model, usage):
    p = price(model)
    if not p:
        return 0.0
    inp, out = p
    long = LONG_PROMPT.get(family(model))
    prompt = (
        usage.get("input_tokens", 0)
        + usage.get("cache_read_input_tokens", 0)
        + usage.get("cache_creation_input_tokens", 0)
    )
    if long and prompt > long[0]:
        inp, out = long[1], long[2]
    created = usage.get("cache_creation") or {}
    w5 = created.get("ephemeral_5m_input_tokens", 0)
    w1 = created.get("ephemeral_1h_input_tokens", 0)
    if w5 + w1 == 0:
        w5 = usage.get("cache_creation_input_tokens", 0)
    return (
        usage.get("input_tokens", 0) * inp
        + usage.get("cache_read_input_tokens", 0) * inp * read_share(model)
        + w5 * inp * 1.25
        + w1 * inp * 2.0
        + usage.get("output_tokens", 0) * out
    )


def transcripts(root):
    return glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)


def records(path):
    with open(path, errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except ValueError:
                continue


class Turn:
    __slots__ = ("ts", "model", "units", "context", "output", "session", "sub", "agent")

    def __init__(self, ts, model, u, context, output, session, sub, agent):
        self.ts, self.model, self.units = ts, model, u
        self.context, self.output = context, output
        self.session, self.sub, self.agent = session, sub, agent


def read_turns(root):
    out = []
    for path in transcripts(root):
        try:
            if os.path.getsize(path) < 200:
                continue
        except OSError:
            continue
        session = agent = None
        sub = False
        for record in records(path):
            if session is None and record.get("sessionId"):
                session = record["sessionId"]
                sub = bool(record.get("isSidechain"))
                agent = record.get("attributionAgent")
            message, ts = record.get("message"), record.get("timestamp")
            if not isinstance(message, dict) or not ts:
                continue
            usage, model = message.get("usage"), message.get("model")
            if not usage or not model:
                continue
            context = (
                usage.get("input_tokens", 0)
                + usage.get("cache_read_input_tokens", 0)
                + usage.get("cache_creation_input_tokens", 0)
            )
            out.append(
                Turn(ts, model, units(model, usage), context,
                     usage.get("output_tokens", 0), session, sub, agent)
            )
    return out


def window(turns, since):
    return [t for t in turns if t.ts >= since] if since else turns


def report_overview(turns, label):
    if not turns:
        print("no activity in window")
        return
    total = sum(t.units for t in turns)
    share = total or 1.0
    ctx = sum(t.context for t in turns)
    print(f"=== {label} ===")
    print(f"  {len(turns):,} turns   {total:,.1f} weighted units")
    print(f"  {ctx / 1e6:,.1f}M tokens read   {sum(t.output for t in turns) / 1e6:,.2f}M written")
    print(f"  mean context re-read per turn: {ctx // len(turns):,}")
    print()

    by_model = defaultdict(lambda: [0, 0.0])
    for t in turns:
        by_model[t.model][0] += 1
        by_model[t.model][1] += t.units
    print("  by model")
    for model, (n, u) in sorted(by_model.items(), key=lambda kv: -kv[1][1]):
        print(f"    {model:24} {n:6,} turns  {u:8,.1f} units  {u / share * 100:5.1f}%")
    print()

    by_session = defaultdict(lambda: [0, 0.0, 0, set(), None])
    for t in turns:
        row = by_session[(t.session, t.sub)]
        row[0] += 1
        row[1] += t.units
        row[2] += t.context
        row[3].add(t.model)
        row[4] = t.agent or row[4]
    print("  top sessions")
    ranked = sorted(by_session.items(), key=lambda kv: -kv[1][1])[:12]
    for (session, sub), (n, u, ctx, models, agent) in ranked:
        tag = f"SUB {agent or '?'}" if sub else "main"
        print(
            f"    {tag:22} {str(session)[:8]}  {n:5,} turns  {u:8,.1f} units"
            f"  ctx/turn {ctx // max(n, 1):>8,}  {','.join(sorted(models))[:24]}"
        )


def report_long(turns):
    by_session = defaultdict(lambda: [0, 0.0, 0, defaultdict(int), 10 ** 12])
    for t in turns:
        if t.sub:
            continue
        row = by_session[t.session]
        row[0] += 1
        row[1] += t.units
        row[2] += t.context
        row[3][t.model] += 1
        row[4] = min(row[4], t.context)

    buckets = [(10, 50), (51, 100), (101, 200), (201, 400), (401, 10 ** 9)]
    print("=== cost per turn rises with session length ===")
    print(f"  {'turns':>12} {'sessions':>9} {'mean ctx/turn':>15} {'units':>10}")
    for lo, hi in buckets:
        group = [v for v in by_session.values() if lo <= v[0] <= hi]
        if not group:
            continue
        label = f"{lo}-{hi}" if hi < 10 ** 9 else f"{lo}+"
        mean_ctx = statistics.mean(v[2] / v[0] for v in group)
        print(f"  {label:>12} {len(group):9} {mean_ctx:15,.0f} {sum(v[1] for v in group):10,.1f}")
    print()

    print("=== sessions worth splitting (est. saving if halved) ===")
    rows = []
    for session, (n, u, ctx, models, floor) in by_session.items():
        if n < 150:
            continue
        dominant = max(models, key=models.get)
        rate = (price(dominant) or (5e-6, 0))[0]
        # Growth-driven reads scale with the square of session length, so
        # splitting in two removes about half of the growth portion.
        growth = ctx - floor * n
        rows.append((growth * 0.25 * rate * 0.1, session, n, u, ctx // n))
    for saving, session, n, u, per in sorted(rows, reverse=True)[:10]:
        print(f"  {str(session)[:8]}  {n:5,} turns  {u:8,.1f} units  ctx/turn {per:>8,}  ~{saving:5.1f} units saved if split")


def report_session(root, session_id):
    target = None
    for path in transcripts(root):
        if os.path.basename(path).startswith(session_id):
            target = path
            break
        for record in records(path):
            if (record.get("sessionId") or "").startswith(session_id):
                target = path
            break
        if target:
            break
    if not target:
        print(f"no transcript for {session_id}")
        return

    names, blocks, turn = {}, [], 0
    for record in records(target):
        # Since CLI v2.1.300 an `api-request-blob` repeats merged turns' content.
        message = record.get("message")
        if record.get("type") not in ("user", "assistant") or not isinstance(message, dict):
            continue
        if message.get("usage"):
            turn += 1
        content = message.get("content")
        role = message.get("role")
        if isinstance(content, str):
            blocks.append((turn, "your message" if role == "user" else "assistant text",
                           len(content), ""))
            continue
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            kind = block.get("type")
            if kind == "text":
                blocks.append((turn, "your message" if role == "user" else "assistant text",
                               len(block.get("text") or ""), ""))
            elif kind == "thinking":
                blocks.append((turn, "thinking", len(block.get("thinking") or ""), ""))
            elif kind == "tool_use":
                names[block.get("id")] = block.get("name", "?")
                blocks.append((turn, "tool call", len(json.dumps(block.get("input") or {})),
                               block.get("name", "?")))
            elif kind == "tool_result":
                body = block.get("content")
                text = body if isinstance(body, str) else json.dumps(body)
                blocks.append((turn, "tool result", len(text or ""),
                               names.get(block.get("tool_use_id"), "?")))

    if not blocks:
        print("no content blocks")
        return
    last = max(b[0] for b in blocks)

    carry = defaultdict(float)
    detail = defaultdict(float)
    for at, kind, chars, tool in blocks:
        cost = (chars / CHARS_PER_TOKEN) * max(last - at, 0)
        carry[kind] += cost
        if tool:
            detail[f"{tool} ({kind.split()[-1]})"] += cost
    total = sum(carry.values()) or 1.0

    print(f"=== {os.path.basename(target)} -- {last} turns ===")
    print("  carry cost = block size x turns it stayed in context")
    print()
    for kind, value in sorted(carry.items(), key=lambda kv: -kv[1]):
        print(f"    {kind:16} {value / 1e6:7.1f}M token-reads  {value / total * 100:5.1f}%")
    print()
    print("  worst carriers")
    for name, value in sorted(detail.items(), key=lambda kv: -kv[1])[:8]:
        print(f"    {name:26} {value / 1e6:7.1f}M  {value / total * 100:5.1f}%")
    print()
    print("  most expensive single blocks")
    ranked = sorted(((c / CHARS_PER_TOKEN) * max(last - a, 0), a, k, c / CHARS_PER_TOKEN, d)
                    for a, k, c, d in blocks)[::-1][:8]
    for cost, at, kind, tokens, tool in ranked:
        print(f"    turn {at:4}/{last}  {kind:13} {tool:16} {tokens:7,.0f} tok"
              f"  x{last - at:4} turns = {cost / 1e6:5.1f}M")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    parser.add_argument("--hours", type=float)
    parser.add_argument("--days", type=float)
    parser.add_argument("--session")
    parser.add_argument("--long", action="store_true")
    args = parser.parse_args()

    if args.session:
        report_session(args.root, args.session)
        return

    turns = read_turns(args.root)
    if not turns:
        print(f"no transcripts under {args.root}")
        sys.exit(1)

    # Said out loud, because every read of `message.usage` below defaults a
    # missing key to 0. Renamed upstream, this would print a confident report of
    # near-nothing and exit 0 — and `recheck.sh` would file that as a reading
    # still holding. The three fields are the reading; if none of them is ever
    # there, there is nothing here to trust.
    if not any(turn.context for turn in turns):
        print("no turn carried input_tokens, cache_read_input_tokens or "
              "cache_creation_input_tokens — the fields this reads by have moved")
        sys.exit(1)

    if args.long:
        report_long(turns)
        return

    hours = args.hours if args.hours else (args.days * 24 if args.days else 24)
    newest = max(t.ts for t in turns)
    cutoff = (datetime.fromisoformat(newest.replace("Z", "+00:00"))
              - timedelta(hours=hours)).isoformat()
    label = f"last {hours:g}h (to {newest[:16]}Z)"
    report_overview(window(turns, cutoff), label)


if __name__ == "__main__":
    main()
