#!/usr/bin/env python3
"""Renders a Claude Code session's conversation as a collapsed markdown block for
a pull request body. A standalone port of Dex's `ConversationMarkdown` and the
transcript reading under it, on the standard library alone, so it runs where
Dex isn't built.
"""

from __future__ import annotations

import base64
import json
import math
import os
import re
import sys
import unicodedata
import urllib.parse
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------- text measures

WHITESPACE = (
    "\t\n\v\f\r \u0085\u00a0\u1680\u2028\u2029\u202f\u205f\u3000"
    + "".join(chr(cp) for cp in range(0x2000, 0x200B))
)

ZWJ = 0x200D
_RI = range(0x1F1E6, 0x1F200)
_PREPEND = set(range(0x600, 0x606)) | {
    0x6DD, 0x70F, 0x890, 0x891, 0x8E2, 0xD4E, 0x110BD, 0x110CD, 0x111C2,
    0x111C3, 0x1193F, 0x11941, 0x11A3A, 0x11D46, 0x11F02,
} | set(range(0x11A84, 0x11A8A))
_EXTEND_EXTRA = (
    {0x200C, 0xFF9E, 0xFF9F}
    | set(range(0x1F3FB, 0x1F400))
    | set(range(0xE0020, 0xE0080))
)
_SPACINGMARK_EXTRA = {0x0E33, 0x0EB3}
_SPACINGMARK_EXCEPT = {
    0x102B, 0x102C, 0x1038, 0x1062, 0x1063, 0x1064, 0x1067, 0x1068, 0x1069,
    0x106A, 0x106B, 0x106C, 0x106D, 0x1083, 0x1087, 0x1088, 0x1089, 0x108A,
    0x108B, 0x108C, 0x108F, 0x109A, 0x109B, 0x109C, 0x1A61, 0x1A63, 0x1A64,
    0xAA7B, 0xAA7D, 0x11720, 0x11721,
}
_PICT_SINGLE = {
    0xA9, 0xAE, 0x203C, 0x2049, 0x2122, 0x2139, 0x3030, 0x303D, 0x3297, 0x3299,
    0x2328, 0x2388, 0x23CF, 0x24C2, 0x25B6, 0x25C0, 0x2B50, 0x2B55,
}
_PICT_RANGES = (
    (0x2194, 0x2199), (0x21A9, 0x21AA), (0x231A, 0x231B), (0x23E9, 0x23F3),
    (0x23F8, 0x23FA), (0x25AA, 0x25AB), (0x25FB, 0x25FE), (0x2600, 0x27BF),
    (0x2934, 0x2935), (0x2B05, 0x2B07), (0x2B1B, 0x2B1C), (0x1F000, 0x1FAFF),
    (0x1FC00, 0x1FFFD),
)


def _is_pict(cp: int) -> bool:
    if cp in _RI:
        return False
    if cp in _PICT_SINGLE:
        return True
    return any(low <= cp <= high for low, high in _PICT_RANGES)


def _is_extend(cp: int) -> bool:
    return unicodedata.category(chr(cp)) in ("Mn", "Me") or cp in _EXTEND_EXTRA


def _is_control(cp: int) -> bool:
    if cp in (0x0A, 0x0D, 0x200C, ZWJ):
        return False
    if cp in _PREPEND:
        return False
    return unicodedata.category(chr(cp)) in ("Cc", "Cf", "Zl", "Zp")


def _is_spacing_mark(cp: int) -> bool:
    if cp in _SPACINGMARK_EXTRA:
        return True
    return unicodedata.category(chr(cp)) == "Mc" and cp not in _SPACINGMARK_EXCEPT


def _hangul(cp: int) -> str | None:
    if 0x1100 <= cp <= 0x115F or 0xA960 <= cp <= 0xA97C:
        return "L"
    if 0x1160 <= cp <= 0x11A7 or 0xD7B0 <= cp <= 0xD7C6:
        return "V"
    if 0x11A8 <= cp <= 0x11FF or 0xD7CB <= cp <= 0xD7FB:
        return "T"
    if 0xAC00 <= cp <= 0xD7A3:
        return "LV" if (cp - 0xAC00) % 28 == 0 else "LVT"
    return None


def _breaks_between(p: int, c: int, ri: int, pict: int) -> bool:
    if p == 0x0D and c == 0x0A:
        return False
    if p in (0x0A, 0x0D) or _is_control(p):
        return True
    if c in (0x0A, 0x0D) or _is_control(c):
        return True
    ph, ch = _hangul(p), _hangul(c)
    if ph == "L" and ch in ("L", "V", "LV", "LVT"):
        return False
    if ph in ("LV", "V") and ch in ("V", "T"):
        return False
    if ph in ("LVT", "T") and ch == "T":
        return False
    if _is_extend(c) or c == ZWJ:
        return False
    if _is_spacing_mark(c):
        return False
    if p in _PREPEND:
        return False
    if pict == 2 and p == ZWJ and _is_pict(c):
        return False
    if p in _RI and c in _RI and ri % 2 == 1:
        return False
    return True


def cluster_starts(text: str) -> list[int]:
    """Where each extended grapheme cluster begins, the unit Swift's String counts in."""
    starts: list[int] = []
    previous: int | None = None
    ri = 0
    pict = 0
    for index, character in enumerate(text):
        cp = ord(character)
        if previous is not None and 0x20 <= cp < 0x7F and 0x20 <= previous < 0x7F:
            starts.append(index)
            ri = 0
            pict = 0
            previous = cp
            continue
        broke = previous is None or _breaks_between(previous, cp, ri, pict)
        if broke:
            starts.append(index)
        if cp in _RI:
            ri = 1 if broke else ri + 1
        else:
            ri = 0
        if _is_pict(cp):
            pict = 1
        elif pict == 1 and _is_extend(cp):
            pict = 1
        elif pict == 1 and cp == ZWJ:
            pict = 2
        else:
            pict = 0
        previous = cp
    return starts


def length(text: str) -> int:
    if text.isascii():
        return len(text)
    return len(cluster_starts(text))


def prefix(text: str, limit: int) -> str:
    if text.isascii():
        return text[:limit]
    starts = cluster_starts(text)
    if limit >= len(starts):
        return text
    return text[: starts[limit]]


def grouped(value: int) -> str:
    return f"{value:,}"


# --------------------------------------------------------------------- Format

def _rounded(value: float) -> int:
    return math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5)


def _tenths(value: float) -> float:
    return _rounded(value * 10) / 10


def _scaled(value: float, suffix: str) -> str:
    text = str(int(value)) if value == float(_rounded(value)) else "%.1f" % value
    return text + suffix


def format_compact(value: int) -> str:
    if value < 1000:
        return str(value)
    thousands = _tenths(value / 1000)
    if thousands < 1000:
        return _scaled(thousands, "k")
    return _scaled(_tenths(thousands / 1000), "M")


def format_elapsed(seconds: float) -> str:
    whole = _rounded(max(0.0, seconds))
    if whole < 60:
        return f"{whole}s"
    hours, rest = divmod(whole, 3600)
    minutes, seconds = divmod(rest, 60)
    parts = [f"{hours}h", f"{minutes}m", f"{seconds}s"] if hours else [f"{minutes}m", f"{seconds}s"]
    while len(parts) > 1 and parts[-1].startswith("0"):
        parts.pop()
    return " ".join(parts)


def tilde_path(path: str, home: str | None = None) -> str:
    home = os.path.expanduser("~") if home is None else home
    if path == home:
        return "~"
    if path.startswith(home + "/"):
        return "~" + path[len(home):]
    return path


def short_path(path: str, home: str | None = None) -> str:
    display = tilde_path(path, home)
    if display == "~":
        return display
    parts = display.split("/")
    if len(parts) <= 3:
        return display
    return "…/" + "/".join(parts[-2:])


# ------------------------------------------------------------- TranscriptText

MID_TURN_LEAD = "The user sent a new message while you were working:"
MID_TURN_NOTE = "This is how Claude Code surfaces messages the user sends mid-turn"
SYNTHETIC_MODEL = "<synthetic>"
INTERRUPTION_LEAD = "[Request interrupted by user"
# What a resume writes for a call its session died holding (CLI v2.1.281).
UNRECORDED_OUTCOME_LEAD = "[Tool call interrupted: the session ended before this call's result was recorded"
NAMED_PEER = "From `"
UNNAMED_PEER = "From another session:"


def content_of_tag(tag: str, text: str) -> str | None:
    opening, closing = f"<{tag}>", f"</{tag}>"
    start = text.find(opening)
    if start < 0:
        return None
    end = text.find(closing, start + len(opening))
    if end < 0:
        return None
    return text[start + len(opening):end]


def _field(tag: str, text: str) -> str | None:
    found = content_of_tag(tag, text)
    return None if found is None else found.strip(WHITESPACE)


def replacing_tag(tag: str, text: str, keeping) -> str:
    opening, closing = f"<{tag}>", f"</{tag}>"
    value = text
    at = 0
    while True:
        start = value.find(opening, at)
        if start < 0:
            return value
        end = value.find(closing, start + len(opening))
        if end < 0:
            return value
        kept = keeping(value[start + len(opening):end]) or ""
        # Resuming past what was written is what lets a kept message carry the tag.
        at = start + len(kept)
        value = value[:start] + kept + value[end + len(closing):]


def removing_tag(tag: str, text: str) -> str:
    return replacing_tag(tag, text, lambda _: None)


def mid_turn_message(reminder: str) -> str | None:
    body = reminder.strip(WHITESPACE)
    if not body.startswith(MID_TURN_LEAD):
        return None
    message = body[len(MID_TURN_LEAD):]
    note = message.find(MID_TURN_NOTE)
    if note >= 0:
        message = message[:note]
    return message.strip(WHITESPACE)


def peer_text(name: str | None, body: str) -> str:
    if not name:
        return f"{UNNAMED_PEER}\n\n{body}"
    return f"{NAMED_PEER}{name}`:\n\n{body}"


def _wrapped(text: str, tag: str, attribute: str) -> tuple[str | None, str] | None:
    open_at = text.find(f"<{tag}")
    if open_at < 0:
        return None
    open_end = text.find(">", open_at + len(tag) + 1)
    if open_end < 0:
        return None
    close = text.find(f"</{tag}>", open_end + 1)
    if close < 0:
        return None
    opening = text[open_at + len(tag) + 1:open_end]
    name = None
    marker = f'{attribute}="'
    found = opening.find(marker)
    if found >= 0:
        quote = opening.find('"', found + len(marker))
        if quote >= 0:
            name = opening[found + len(marker):quote]
    body = text[open_end + 1:close].strip(WHITESPACE)
    if not body:
        return None
    return name, body


def peer_unwrapping(text: str) -> str | None:
    sent = _wrapped(text, "cross-session-message", "from-name")
    if sent is not None:
        return peer_text(sent[0], sent[1])
    reported = _wrapped(text, "agent-message", "from")
    if reported is None:
        return None
    return peer_text(reported[0], handback_report(reported[1]))


HANDBACK_LEAD = "[Subagent hand-back]"
HARNESS_LEAD = "[harness:"


def handback_report(text: str) -> str:
    """A subagent's report without the frame the CLI wraps it in: a line saying
    the report is model output and carries no authority, sometimes a line of the
    harness's own, and the report itself indented two spaces so that nothing in
    it can forge a line of the frame. None of that is the report."""
    lines = text.split("\n")
    if not lines or not lines[0].startswith(HANDBACK_LEAD):
        return text
    kept = lines[1:]
    while kept and not kept[0].strip(WHITESPACE):
        kept.pop(0)
    if kept and kept[0].strip(WHITESPACE).startswith(HARNESS_LEAD):
        kept.pop(0)
    return "\n".join(
        line[2:] if line.startswith("  ") else line for line in kept
    ).strip(WHITESPACE)


def cleaned(text: str) -> str:
    value = replacing_tag("system-reminder", text, mid_turn_message)
    for tag in ("task-notification", "usage", "local-command-stdout", "command-message"):
        value = removing_tag(tag, value)

    name = content_of_tag("command-name", value)
    if name is not None:
        arguments = content_of_tag("command-args", value) or ""
        value = " ".join(
            part for part in (name.strip(WHITESPACE), arguments.strip(WHITESPACE)) if part
        )

    peer = peer_unwrapping(value)
    if peer is not None:
        return peer

    return value.strip(WHITESPACE)


def unremindered_summary(text: str) -> str:
    return replacing_tag(
        "system-reminder",
        text,
        lambda reminder: None
        if "<tools-used-before-summary>" in reminder
        else f"<system-reminder>{reminder}</system-reminder>",
    )


def launched_agent_id(text: str) -> str | None:
    if "Async agent launched" not in text:
        return None
    anchor = text.find("agentId: ")
    if anchor < 0:
        return None
    rest = text[anchor + len("agentId: "):]
    taken = 0
    while taken < len(rest) and rest[taken] in "0123456789abcdefABCDEF":
        taken += 1
    return rest[:taken] or None


def clipped(text: str, limit: int) -> str:
    size = length(text)
    if size <= limit:
        return text
    return prefix(text, limit) + f"\n\n… {grouped(size - limit)} more characters"


def is_interruption(text: str) -> bool:
    line = text.strip(WHITESPACE)
    return line.startswith(INTERRUPTION_LEAD) and line.endswith("]") and "\n" not in line


def unbracketed(text: str) -> str:
    line = text.strip(WHITESPACE)
    if line.startswith("[") and line.endswith("]") and length(line) > 2:
        return line[1:-1]
    return line


class SubagentTotals:
    def __init__(self, tool_uses: int, tokens: int, duration: float):
        self.tool_uses = tool_uses
        self.tokens = tokens
        self.duration = duration

    @property
    def summary(self) -> str:
        uses = "1 tool use" if self.tool_uses == 1 else f"{self.tool_uses} tool uses"
        return " · ".join(
            [uses, f"{format_compact(self.tokens)} tokens", format_elapsed(self.duration)]
        )


class FinishedAgent:
    def __init__(self, tool_use_id, task_id, summary, failed, totals, interim):
        self.tool_use_id = tool_use_id
        self.task_id = task_id
        self.summary = summary
        self.failed = failed
        self.totals = totals
        self.interim = interim


def _totals_in(text: str) -> SubagentTotals | None:
    usage = content_of_tag("usage", text)
    if usage is None:
        return None
    uses, tokens, milliseconds = (
        _field("tool_uses", usage), _field("subagent_tokens", usage), _field("duration_ms", usage)
    )
    try:
        return SubagentTotals(int(uses), int(tokens), float(milliseconds) / 1000)
    except (TypeError, ValueError):
        return None


def finished_agents(text: str) -> list[FinishedAgent]:
    agents: list[FinishedAgent] = []
    at = 0
    while True:
        start = text.find("<task-notification>", at)
        if start < 0:
            return agents
        end = text.find("</task-notification>", start + len("<task-notification>"))
        if end < 0:
            return agents
        notice = text[start + len("<task-notification>"):end]
        after = end + len("</task-notification>")
        following = text.find("<task-notification>", after)
        beside = text[after:] if following < 0 else text[after:following]
        at = after

        tool_use_id = _field("tool-use-id", notice) or None
        task_id = _field("task-id", notice) or None
        if not tool_use_id and not task_id:
            continue
        status = _field("status", notice)
        if status is None:
            continue
        agents.append(
            FinishedAgent(
                tool_use_id,
                task_id,
                content_of_tag("summary", notice),
                status != "completed",
                _totals_in(notice) or _totals_in(beside),
                "interim" in (_field("note", notice) or ""),
            )
        )


# ------------------------------------------------------------ record decoding

class Drop(Exception):
    """The record's own fields contradict their types, so Swift drops the line."""


def _string(fields: dict, key: str) -> str | None:
    value = fields.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise Drop
    return value


def _bool(fields: dict, key: str) -> bool | None:
    value = fields.get(key)
    if value is None:
        return None
    if not isinstance(value, bool):
        raise Drop
    return value


def _int(fields: dict, key: str) -> int | None:
    value = fields.get(key)
    if value is None:
        return None
    if isinstance(value, bool):
        raise Drop
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    raise Drop


def _maybe_string(value) -> str | None:
    return value if isinstance(value, str) else None


def _maybe_int(value) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


def _maybe_float(value) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def scalar_text(value) -> str | None:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        number = float(value)
        if number == float(_rounded(number)) and abs(number) < 1e15:
            return str(int(number))
        return repr(number)
    return None


class Block:
    KIND = ""


class TextBlock(Block):
    KIND = "text"

    def __init__(self, text: str):
        self.text = text


class ThinkingBlock(Block):
    KIND = "thinking"

    def __init__(self, text: str, is_narration: bool):
        self.text = text
        self.is_narration = is_narration


class ToolUseBlock(Block):
    KIND = "tool_use"

    def __init__(self, tool_id: str, name: str, payload):
        self.tool_id = tool_id
        self.name = name
        self.payload = payload


class ToolResultBlock(Block):
    KIND = "tool_result"

    def __init__(self, tool_use_id: str, text: str, is_error: bool):
        self.tool_use_id = tool_use_id
        self.text = text
        self.is_error = is_error


class ImageBlock(Block):
    KIND = "image"

    def __init__(self, media_type: str | None, size: int):
        self.media_type = media_type
        self.size = size

    @property
    def label(self) -> str:
        return image_label(self.media_type, self.size)


class OtherBlock(Block):
    KIND = "other"


def image_label(media_type: str | None, size: int) -> str:
    kind = "Image"
    subtype = media_type.split("/")[-1] if media_type else ""
    if subtype:
        kind = f"{subtype.upper()} image"
    if size <= 0:
        return kind
    if size < 1_000_000:
        return f"{kind}, {max(1, (size + 500) // 1000)} KB"
    return f"{kind}, {size / 1_000_000:.1f} MB"


def _image_block(fields: dict) -> ImageBlock:
    source = fields.get("source")
    source = source if isinstance(source, dict) else {}
    data = _maybe_string(source.get("data")) or ""
    padding = data[-2:].count("=")
    return ImageBlock(_maybe_string(source.get("media_type")), max(0, len(data) // 4 * 3 - padding))


_ANONYMOUS = 0


def _anonymous() -> str:
    global _ANONYMOUS
    _ANONYMOUS += 1
    return f"anonymous.{_ANONYMOUS}"


def _result_text(fields: dict) -> str:
    content = fields.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    texts = []
    for item in content:
        if isinstance(item, dict):
            if item.get("type") == "image":
                texts.append(f"[{_image_block(item).label}]")
                continue
            text = item.get("text")
            if isinstance(text, str):
                texts.append(text)
    return "\n".join(texts)


def _parse_block(fields: dict) -> Block:
    kind = _maybe_string(fields.get("type"))
    if kind == "text":
        return TextBlock(_maybe_string(fields.get("text")) or "")
    if kind == "thinking":
        return ThinkingBlock(
            _maybe_string(fields.get("thinking")) or "",
            is_narration(_maybe_string(fields.get("signature"))),
        )
    if kind == "tool_use":
        return ToolUseBlock(
            _maybe_string(fields.get("id")) or _anonymous(),
            _maybe_string(fields.get("name")) or "Tool",
            fields.get("input"),
        )
    if kind == "tool_result":
        return ToolResultBlock(
            _maybe_string(fields.get("tool_use_id")) or "",
            _result_text(fields),
            fields.get("is_error") is True,
        )
    if kind == "image":
        return _image_block(fields)
    return OtherBlock()


class Message:
    def __init__(self, blocks: list[Block], model: str | None):
        self.blocks = blocks
        self.model = model


def _parse_message(value) -> Message:
    if not isinstance(value, dict):
        raise Drop
    content = value.get("content")
    if isinstance(content, str):
        blocks = [TextBlock(content)]
    elif isinstance(content, list):
        blocks = []
        for item in content:
            if not isinstance(item, dict):
                blocks = []
                break
            blocks.append(_parse_block(item))
    else:
        blocks = []
    return Message(blocks, _maybe_string(value.get("model")))


class CollectedTask:
    OVER = {"completed", "failed", "killed", "cancelled"}

    def __init__(self, task_id: str, status: str):
        self.task_id = task_id
        self.status = status

    @property
    def is_over(self) -> bool:
        return self.status in self.OVER

    @property
    def failed(self) -> bool:
        return self.status != "completed"


class RawToolResult:
    def __init__(self, value):
        self.answers: dict[str, str] = {}
        self.notes: dict[str, str] = {}
        self.response: str | None = None
        self.subagent: SubagentTotals | None = None
        self.is_launch = False
        self.plan_was_edited = False
        self.agent_id: str | None = None
        self.collected: CollectedTask | None = None
        if not isinstance(value, dict):
            return

        given = value.get("answers")
        if isinstance(given, dict):
            for key, item in given.items():
                text = self._answer_text(item)
                if text is not None:
                    self.answers[key] = text

        self.notes = self._annotations(value.get("annotations"))
        self.response = _maybe_string(value.get("response")) or None
        self.subagent = self._totals(value)
        self.is_launch = _maybe_string(value.get("status")) == "async_launched"
        self.plan_was_edited = value.get("planWasEdited") is True
        self.agent_id = _maybe_string(value.get("agentId"))
        if _maybe_string(value.get("retrieval_status")) == "success":
            task = value.get("task")
            if isinstance(task, dict):
                task_id = _maybe_string(task.get("task_id"))
                status = _maybe_string(task.get("status"))
                if task_id is not None and status is not None:
                    self.collected = CollectedTask(task_id, status)

    @staticmethod
    def _answer_text(value) -> str | None:
        scalar = scalar_text(value)
        if scalar is not None:
            return scalar
        if not isinstance(value, list):
            return None
        texts = (scalar_text(item) for item in value)
        joined = ", ".join(text for text in texts if text is not None)
        return joined or None

    @staticmethod
    def _annotations(value) -> dict[str, str]:
        if not isinstance(value, dict):
            return {}
        notes: dict[str, str] = {}
        for key, item in value.items():
            if not isinstance(item, dict):
                return {}
            note = item.get("notes")
            if note is None:
                continue
            if not isinstance(note, str):
                return {}
            notes[key] = note
        return notes

    @staticmethod
    def _totals(value: dict) -> SubagentTotals | None:
        uses = _maybe_int(value.get("totalToolUseCount"))
        tokens = _maybe_int(value.get("totalTokens"))
        milliseconds = _maybe_float(value.get("totalDurationMs"))
        if uses is None or tokens is None or milliseconds is None:
            return None
        return SubagentTotals(uses, tokens, milliseconds / 1000)


class Origin:
    def __init__(self, value):
        if not isinstance(value, dict):
            raise Drop
        self.kind = _string(value, "kind")
        self.name = _string(value, "name")
        self.sender = _string(value, "from")
        self.handback = _bool(value, "handback")
        self.body = _string(value, "body")

    @property
    def is_peer(self) -> bool:
        return self.kind == "peer"

    @property
    def is_handback(self) -> bool:
        return self.handback is True


def _tolerant_origin(value) -> Origin | None:
    try:
        return Origin(value)
    except Drop:
        return None


class Attachment:
    def __init__(self, value):
        self.images: list[ImageBlock] = []
        if not isinstance(value, dict):
            self.type = self.prompt = self.command_mode = self.origin = None
            return
        self.type = _maybe_string(value.get("type"))
        prompt = value.get("prompt")
        # A pasted image turns the prompt into a block array.
        if isinstance(prompt, list):
            blocks = [_parse_block(item) for item in prompt if isinstance(item, dict)]
            texts = [block.text for block in blocks if isinstance(block, TextBlock)]
            self.prompt = "\n".join(texts) if texts else None
            self.images = [block for block in blocks if isinstance(block, ImageBlock)]
        else:
            self.prompt = _maybe_string(prompt)
        self.command_mode = _maybe_string(value.get("commandMode"))
        self.origin = (
            _tolerant_origin(value.get("origin")) if value.get("origin") is not None else None
        )


class CompactMetadata:
    def __init__(self, value):
        if not isinstance(value, dict):
            raise Drop
        self.trigger = _string(value, "trigger")
        self.pre_tokens = _int(value, "preTokens")
        self.post_tokens = _int(value, "postTokens")
        self.duration_ms = _int(value, "durationMs")


class Record:
    def __init__(self, fields: dict):
        kind = fields.get("type")
        if not isinstance(kind, str):
            raise Drop
        self.type = kind
        self.subtype = _string(fields, "subtype")
        self.uuid = _string(fields, "uuid")
        self.timestamp = _string(fields, "timestamp")
        self.is_sidechain = _bool(fields, "isSidechain")
        self.is_meta = _bool(fields, "isMeta")
        self.message = (
            _parse_message(fields["message"]) if fields.get("message") is not None else None
        )
        self.tool_use_result = (
            RawToolResult(fields["toolUseResult"])
            if fields.get("toolUseResult") is not None
            else None
        )
        self.is_api_error_message = _bool(fields, "isApiErrorMessage")
        self.effort = _string(fields, "effort")
        self.ai_title = _string(fields, "aiTitle")
        self.custom_title = _string(fields, "customTitle")
        self.operation = _string(fields, "operation")
        self.content = fields.get("content")
        self.attachment = (
            Attachment(fields["attachment"]) if fields.get("attachment") is not None else None
        )
        self.origin = Origin(fields["origin"]) if fields.get("origin") is not None else None
        self.is_compact_summary = _bool(fields, "isCompactSummary")
        self.compact_metadata = (
            CompactMetadata(fields["compactMetadata"])
            if fields.get("compactMetadata") is not None
            else None
        )

    @property
    def blocks(self) -> list[Block]:
        return self.message.blocks if self.message else []

    @property
    def queued_text(self) -> str | None:
        return self.content if isinstance(self.content, str) else None

    @property
    def is_compact_boundary(self) -> bool:
        return self.type == "system" and self.subtype == "compact_boundary"

    @property
    def role(self) -> str | None:
        if self.type == "user":
            return "user"
        if self.type == "assistant":
            return "assistant"
        return None

    @property
    def at(self) -> datetime | None:
        return parse_timestamp(self.timestamp)

    @property
    def is_synthetic(self) -> bool:
        return bool(self.message) and self.message.model == SYNTHETIC_MODEL

    @property
    def is_interruption(self) -> bool:
        blocks = self.blocks
        if len(blocks) != 1 or not isinstance(blocks[0], TextBlock):
            return False
        return is_interruption(blocks[0].text)


def decode_record(line: bytes | str) -> Record | None:
    try:
        fields = json.loads(line)
    except (ValueError, UnicodeDecodeError, RecursionError):
        return None
    if not isinstance(fields, dict):
        return None
    try:
        return Record(fields)
    except Drop:
        return None


_STAMP = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?"
    r"(?:[Zz]|([+-])(\d{2}):?(\d{2}))$"
)


def parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    match = _STAMP.match(value)
    if not match:
        return None
    year, month, day, hour, minute, second, fraction, sign, offset_h, offset_m = match.groups()
    microsecond = int((fraction or "").ljust(6, "0")[:6])
    zone = timezone.utc
    if sign:
        minutes = int(offset_h) * 60 + int(offset_m)
        delta = timedelta(minutes=minutes)
        zone = timezone(-delta if sign == "-" else delta)
    return datetime(
        int(year), int(month), int(day), int(hour), int(minute), int(second), microsecond, zone
    )


# ------------------------------------------------------- narration signature

NARRATION = "narration"


def is_narration(signature: str | None) -> bool:
    if signature is None:
        return False
    return block_kind(signature) == NARRATION


def block_kind(signature: str) -> str | None:
    payload = _decode_base64(signature)
    if payload is None:
        return None
    envelope = _protobuf_field(payload, 2)
    if envelope is None:
        return None
    inner = _protobuf_field(envelope, 1)
    if inner is None:
        return None
    kind = _protobuf_field(inner, 8)
    if kind is None:
        return None
    try:
        return kind.decode("utf-8")
    except UnicodeDecodeError:
        return None


def _decode_base64(signature: str) -> bytes | None:
    exact = _strict_base64(signature)
    if exact is not None:
        return exact
    short = len(signature) % 4
    if short == 0:
        return None
    return _strict_base64(signature + "=" * (4 - short))


def _strict_base64(text: str) -> bytes | None:
    if len(text) % 4 != 0:
        return None
    try:
        return base64.b64decode(text, validate=True)
    except ValueError:
        return None


def _varint(payload: bytes, start: int):
    value = 0
    shift = 0
    for step in range(10):
        at = start + step
        if at >= len(payload):
            return None
        byte = payload[at]
        value |= (byte & 127) << shift
        if byte & 128 == 0:
            return value, at + 1
        shift += 7
    return None


def _protobuf_field(payload: bytes, wanted: int) -> bytes | None:
    found = None
    at = 0
    end = len(payload)
    while at < end:
        tag = _varint(payload, at)
        if tag is None:
            return None
        value, at = tag
        wire = value & 7
        number = value >> 3
        if wire == 0:
            skipped = _varint(payload, at)
            if skipped is None:
                return None
            at = skipped[1]
        elif wire == 1:
            if at + 8 > end:
                return None
            at += 8
        elif wire == 2:
            header = _varint(payload, at)
            if header is None:
                return None
            size, start = header
            if size > end - start:
                return None
            stop = start + size
            if number == wanted:
                found = payload[start:stop]
            at = stop
        elif wire == 5:
            if at + 4 > end:
                return None
            at += 4
        else:
            return None
    return found


# ------------------------------------------------------------------ tool call

class ToolResult:
    def __init__(self, text="", is_error=False, answers=None, notes=None, response=None,
                 subagent=None, plan_was_edited=False):
        self.text = text
        self.is_error = is_error
        self.answers = answers or {}
        self.notes = notes or {}
        self.response = response
        self.subagent = subagent
        self.plan_was_edited = plan_was_edited

    @property
    def is_unrecorded(self) -> bool:
        return self.is_error and self.text.strip().startswith(UNRECORDED_OUTCOME_LEAD)


class AskedQuestion:
    def __init__(self, header, question, answer, note):
        self.header = header
        self.question = question
        self.answer = answer
        self.note = note


MEDIA_REMOVED = "[media removed: request limit]"
DROPPED_NOTE = "too large to send, never seen"


class ToolCall:
    def __init__(self, tool_id: str, name: str, payload, started_at=None):
        self.id = tool_id
        self.name = name
        self.payload = payload
        self.started_at = started_at
        self.finished_at = None
        self.result: ToolResult | None = None
        self.agent_id: str | None = None
        # Its file was taken out of the request to fit; the model saw the placeholder.
        self.was_dropped = False

    @property
    def fields(self) -> dict | None:
        return self.payload if isinstance(self.payload, dict) else None

    def argument(self, key: str) -> str | None:
        fields = self.fields
        if fields is None:
            return None
        value = scalar_text(fields.get(key))
        return value or None

    @property
    def is_pending(self) -> bool:
        return self.result is None

    @property
    def is_question(self) -> bool:
        return self.name == "AskUserQuestion"

    @property
    def is_delegation(self) -> bool:
        return self.name in ("Task", "Agent")

    @property
    def is_plan(self) -> bool:
        return self.name == "ExitPlanMode"

    @property
    def proposed_plan(self) -> str | None:
        plan = self.argument("plan")
        if plan is not None:
            return plan
        path = self.argument("planFilePath")
        if path is None:
            return None
        try:
            with open(path, encoding="utf-8") as handle:
                return handle.read()
        except OSError:
            return None

    @property
    def plan_outcome(self):
        if self.result is None or self.result.is_unrecorded:
            return ("waiting", None)
        if not self.result.is_error:
            return ("approved", self.result.plan_was_edited)
        return ("rejected", self._rejection(self.result.text))

    @staticmethod
    def _rejection(text: str) -> str | None:
        anchor = "the user said:"
        at = text.find(anchor)
        if at < 0:
            return None
        said = text[at + len(anchor):].strip(WHITESPACE)
        return said or None

    @property
    def asked_questions(self) -> list[AskedQuestion]:
        fields = self.fields
        asked = fields.get("questions") if fields else None
        if not isinstance(asked, list):
            return []
        out = []
        for entry in asked:
            if not isinstance(entry, dict):
                continue
            question = _maybe_string(entry.get("question"))
            if not question:
                continue
            answer = None
            if self.result is not None:
                answer = self.result.answers.get(question)
            if answer is None:
                answer = self._answer(question, self.result.text if self.result else "")
            note = self.result.notes.get(question) if self.result else None
            out.append(
                AskedQuestion(_maybe_string(entry.get("header")), question, answer, note)
            )
        return out

    @staticmethod
    def _answer(question: str, reply: str) -> str | None:
        anchor = f'"{question}"="'
        at = reply.find(anchor)
        if at < 0:
            return None
        close = reply.find('"', at + len(anchor))
        if close < 0:
            return None
        value = reply[at + len(anchor):close]
        return value or None

    @property
    def summary(self) -> str | None:
        return _trimmed(self._raw_summary(shortened=True))

    @property
    def purpose(self) -> str | None:
        return _trimmed(self.argument("description")) or self.summary

    def _raw_summary(self, shortened: bool) -> str | None:
        name = self.name
        if name in ("Read", "Write", "NotebookEdit", "Edit", "MultiEdit"):
            path = self.argument("file_path")
            return None if path is None else short_path(path)
        if name in ("Bash", "BashOutput"):
            command = self.argument("command")
            if command is not None:
                return _first_line(command) if shortened else command
            return self.argument("description")
        if name in ("Glob", "Grep"):
            path = self.argument("path")
            parts = [self.argument("pattern"), None if path is None else short_path(path)]
            return "  in  ".join(part for part in parts if part is not None)
        if name in ("Task", "Agent"):
            return self.argument("description") or self.argument("subagent_type")
        if name == "WebFetch":
            return self.argument("url")
        if name == "WebSearch":
            return self.argument("query")
        if name == "TodoWrite":
            return self._todo_summary
        if name == "Skill":
            return self.argument("skill") or self.argument("command")
        if name == "AskUserQuestion":
            return self._question_summary
        if name == "ExitPlanMode":
            return "ready to build"
        return self._fallback_summary

    @property
    def _question_summary(self) -> str | None:
        fields = self.fields
        questions = fields.get("questions") if fields else None
        if not isinstance(questions, list):
            return self.argument("question")
        asked = [
            entry["question"]
            for entry in questions
            if isinstance(entry, dict) and isinstance(entry.get("question"), str)
        ]
        if not asked:
            return None
        return f"{asked[0]} (+{len(asked) - 1} more)" if len(asked) > 1 else asked[0]

    @property
    def _todo_summary(self) -> str | None:
        fields = self.fields
        todos = fields.get("todos") if fields else None
        if not isinstance(todos, list):
            return None
        done = sum(
            1 for todo in todos if isinstance(todo, dict) and todo.get("status") == "completed"
        )
        return f"{done}/{len(todos)} done"

    @property
    def _fallback_summary(self) -> str | None:
        fields = self.fields
        if fields is None:
            return None
        for key in sorted(fields.keys()):
            value = scalar_text(fields.get(key))
            if value:
                return _first_line(value)
        return None


def _trimmed(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = value.strip(WHITESPACE)
    return stripped or None


def _first_line(text: str) -> str:
    stripped = text.strip(WHITESPACE)
    newline = stripped.find("\n")
    if newline < 0:
        return stripped
    return stripped[:newline] + " …"


# ------------------------------------------------------------------- document

class Prose:
    def __init__(self, kind: str, block_id: str, text: str):
        self.kind = kind
        self.id = block_id
        self.text = text


class Image:
    def __init__(self, block_id: str, label: str):
        self.id = block_id
        self.label = label


class Notice:
    def __init__(self, block_id: str, text: str, is_error: bool):
        self.id = block_id
        self.text = text
        self.is_error = is_error


class PeerMessage:
    def __init__(
        self,
        block_id: str,
        direction: str,
        name: str | None,
        body: str,
        address: str | None = None,
    ):
        self.id = block_id
        self.direction = direction
        self.name = name
        self.body = body
        self.address = address


class Compaction:
    def __init__(self, block_id, trigger, pre_tokens, post_tokens, summary=None):
        self.id = block_id
        self.trigger = trigger
        self.pre_tokens = pre_tokens
        self.post_tokens = post_tokens
        self.summary = summary


class Entry:
    def __init__(self, entry_id: str, role: str, at, blocks: list):
        self.id = entry_id
        self.role = role
        self.at = at
        self.blocks = blocks


class Document:
    def __init__(self, keeps_sidechain: bool = False):
        self.entries: list[Entry] = []
        self.keeps_sidechain = keeps_sidechain
        self._call_sites: dict[str, tuple[int, int]] = {}
        # Results no request has carried yet: the CLI strips the oldest files
        # first, so a drop is "never seen" only in the first request after.
        self._unsent: set[str] = set()
        self._agent_calls: dict[str, str] = {}
        self._interim_agents: dict[str, str] = {}
        self._early_collections: dict[str, tuple[CollectedTask, object]] = {}
        self._early: dict[str, dict] = {}
        self._last_compaction: tuple[int, int] | None = None
        self._read: set[str] = set()

    @property
    def is_empty(self) -> bool:
        return not self.entries

    def append_line(self, line: bytes | str) -> None:
        record = decode_record(line)
        if record is not None:
            self.append(record)

    def append(self, record: Record) -> None:
        # A history written twice relaunches every background agent it repeats.
        if record.uuid is not None:
            if record.uuid in self._read:
                return
            self._read.add(record.uuid)
        if not self.keeps_sidechain and record.is_sidechain is True:
            return

        # A queued message has not been said yet, so nothing stands for it here.
        if record.type == "queue-operation":
            return
        if record.type == "attachment":
            self._absorbed_message(record)
            return

        if record.is_compact_boundary:
            self._compacted(record)
            return

        if record.type == "api-request-blob":
            self._dropped(record)
            return
        if record.type == "api-request":
            self._unsent.clear()
            return

        role = record.role
        if role is None:
            return

        if record.is_compact_summary is True:
            self._summarised(record)
            return

        if record.is_meta is True:
            if role == "user" and record.origin is not None and record.origin.is_peer:
                self._peer_message(record.origin, record.uuid, record.at)
            return

        blocks: list = []
        opened: list[str] = []
        entry_id = record.uuid or _anonymous()

        for index, raw in enumerate(record.blocks):
            if isinstance(raw, TextBlock):
                if role == "user":
                    self._bring_agents_back(raw.text, record.at)
                text = cleaned(raw.text) if role == "user" else raw.text
                if not text:
                    continue
                if record.is_synthetic or record.is_interruption:
                    blocks.append(
                        Notice(
                            f"{entry_id}.{index}",
                            unbracketed(text),
                            record.is_api_error_message is True,
                        )
                    )
                    continue
                blocks.append(Prose("prose", f"{entry_id}.{index}", text))

            elif isinstance(raw, ThinkingBlock):
                if not raw.text:
                    continue
                kind = "narration" if raw.is_narration else "thinking"
                blocks.append(Prose(kind, f"{entry_id}.{index}", raw.text))

            elif isinstance(raw, ToolUseBlock):
                self._call_sites[raw.tool_id] = (len(self.entries), len(blocks))
                opened.append(raw.tool_id)
                blocks.append(ToolCall(raw.tool_id, raw.name, raw.payload, record.at))

            elif isinstance(raw, ToolResultBlock):
                launched = launched_agent_id(raw.text)
                answer = record.tool_use_result
                named = (answer.agent_id if answer else None) or launched
                if named:
                    self._note_agent(named, raw.tool_use_id)

                if answer is not None and answer.collected is not None:
                    self._bring_agent_back(answer.collected, record.at)

                if (answer is not None and answer.is_launch) or launched is not None:
                    continue

                self._unsent.add(raw.tool_use_id)
                self._attach(
                    ToolResult(
                        text=raw.text,
                        is_error=raw.is_error,
                        answers=answer.answers if answer else {},
                        notes=answer.notes if answer else {},
                        response=answer.response if answer else None,
                        subagent=answer.subagent if answer else None,
                        plan_was_edited=bool(answer and answer.plan_was_edited),
                    ),
                    raw.tool_use_id,
                    record.at,
                )

            elif isinstance(raw, ImageBlock):
                blocks.append(Image(f"{entry_id}.{index}", raw.label))

        if not blocks:
            return

        self.entries.append(Entry(entry_id, role, record.at, blocks))
        for tool_id in opened:
            self._settle(tool_id)

    def _compacted(self, record: Record) -> None:
        entry_id = record.uuid or _anonymous()
        metadata = record.compact_metadata
        compaction = Compaction(
            entry_id,
            metadata.trigger if metadata else None,
            metadata.pre_tokens if metadata else None,
            metadata.post_tokens if metadata else None,
        )
        self._last_compaction = (len(self.entries), 0)
        self.entries.append(Entry(entry_id, "system", record.at, [compaction]))

    def _summarised(self, record: Record) -> None:
        text = unremindered_summary(
            "\n".join(b.text for b in record.blocks if isinstance(b, TextBlock))
        )
        if not text:
            return
        site = self._last_compaction
        if site is not None:
            block = self.entries[site[0]].blocks[site[1]]
            if isinstance(block, Compaction) and block.summary is None:
                block.summary = text
                return
        entry_id = record.uuid or _anonymous()
        compaction = Compaction(entry_id, None, None, None, summary=text)
        self._last_compaction = (len(self.entries), 0)
        self.entries.append(Entry(entry_id, "system", record.at, [compaction]))

    def _absorbed_message(self, record: Record) -> None:
        attachment = record.attachment
        if attachment is None or attachment.type != "queued_command" or attachment.prompt is None:
            return

        if attachment.command_mode == "task-notification":
            self._bring_agents_back(attachment.prompt, record.at)
            return

        if attachment.command_mode != "prompt":
            return

        if attachment.origin is not None and attachment.origin.is_peer:
            self._peer_message(attachment.origin, record.uuid, record.at)
            return

        text = cleaned(attachment.prompt)
        if not text:
            return
        self._user_turn(text, record.uuid, record.at, attachment.images)

    def _peer_message(self, origin: Origin, entry_id, at) -> None:
        # A subagent's report arrives by the same door and is not addressed to
        # whoever is reading: it answers the model that sent the agent out, and
        # the agent's own conversation already ends with it.
        if origin.is_handback:
            return

        body = (origin.body or "").strip(WHITESPACE)
        if not body:
            return

        entry_id = entry_id or _anonymous()
        self.entries.append(
            Entry(
                entry_id,
                "user",
                at,
                [PeerMessage(f"{entry_id}.0", "inbound", origin.name or None, body, origin.sender)],
            )
        )

    def _user_turn(self, text: str, entry_id, at, images=()) -> None:
        entry_id = entry_id or _anonymous()
        blocks: list = [Prose("prose", f"{entry_id}.0", text)]
        for index, image in enumerate(images):
            blocks.append(Image(f"{entry_id}.{index + 1}", image.label))
        self.entries.append(Entry(entry_id, "user", at, blocks))

    def _bring_agents_back(self, text: str, at) -> None:
        for agent in finished_agents(text):
            tool_use_id = agent.tool_use_id or self._interim_agents.get(agent.task_id)
            if tool_use_id is None:
                continue
            self._attach(
                ToolResult(
                    text=agent.summary or "", is_error=agent.failed, subagent=agent.totals
                ),
                tool_use_id,
                at,
            )
            if agent.task_id:
                if agent.interim:
                    self._interim_agents[agent.task_id] = tool_use_id
                else:
                    self._interim_agents.pop(agent.task_id, None)

    def _bring_agent_back(self, collected: CollectedTask, at) -> None:
        if not collected.is_over:
            return
        tool_use_id = self._agent_calls.get(collected.task_id)
        if tool_use_id is None:
            self._early_collections[collected.task_id] = (collected, at)
            return
        written = self._written(tool_use_id)
        if written is not None and not written.is_pending:
            return
        self._attach(ToolResult(text="", is_error=collected.failed), tool_use_id, at)

    def _written(self, tool_use_id: str) -> ToolCall | None:
        site = self._call_sites.get(tool_use_id)
        if site is None or site[0] >= len(self.entries):
            return None
        blocks = self.entries[site[0]].blocks
        if site[1] >= len(blocks):
            return None
        block = blocks[site[1]]
        return block if isinstance(block, ToolCall) else None

    def _settle(self, tool_use_id: str) -> None:
        waiting = self._early.pop(tool_use_id, None)
        if waiting is None:
            return
        if waiting.get("agent_id"):
            self._note_agent(waiting["agent_id"], tool_use_id)
        if waiting.get("result") is not None:
            self._attach(waiting["result"], tool_use_id, waiting.get("at"))

    def _dropped(self, record: Record) -> None:
        for raw in record.blocks:
            if (isinstance(raw, ToolResultBlock) and raw.tool_use_id in self._unsent
                    and MEDIA_REMOVED in raw.text.split("\n")):
                call = self._written(raw.tool_use_id)
                if call is not None:
                    call.was_dropped = True

    def _note_agent(self, agent_id: str, tool_use_id: str) -> None:
        # Before the call is found, not after: a receipt ahead of its call would
        # otherwise lose the id for the whole stretch the agent is out.
        self._agent_calls[agent_id] = tool_use_id

        waiting = self._early_collections.pop(agent_id, None)
        if waiting is not None:
            self._bring_agent_back(waiting[0], waiting[1])

        call = self._written(tool_use_id)
        if call is None:
            self._early.setdefault(tool_use_id, {})["agent_id"] = agent_id
            return
        call.agent_id = agent_id

    def _attach(self, result: ToolResult, tool_use_id: str, at) -> None:
        call = self._written(tool_use_id)
        if call is None:
            held = self._early.setdefault(tool_use_id, {})
            held["result"] = result
            held["at"] = at
            return
        call.result = result
        call.finished_at = at


# --------------------------------------------------------- ConversationMarkdown

WRAPPER_OVERHEAD = 120
CLIP_NOTE = 64
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
TAGS = ["</details>", "<details>", "<details ", "</summary>", "<summary>", "<summary "]
_TAG_PATTERNS = [(re.compile(re.escape(tag), re.IGNORECASE), "&lt;" + tag[1:]) for tag in TAGS]


class Options:
    def __init__(self, author="User", assistant="Claude", title=None, session_id=None,
                 max_chars=60_000):
        self.author = author
        self.assistant = assistant
        self.title = title
        self.session_id = session_id
        self.max_chars = max_chars


def escaped(text: str) -> str:
    out = text
    for pattern, replacement in _TAG_PATTERNS:
        out = pattern.sub(replacement, out)
    return out


def image_opens_turn(entry: Entry, block) -> bool:
    """A pasted image with nothing typed beside it is the whole message."""
    if entry.role != "user" or not isinstance(block, Image):
        return False
    if any(isinstance(b, Prose) and b.kind == "prose" for b in entry.blocks):
        return False
    return next(b for b in entry.blocks if isinstance(b, Image)) is block


def render(entries: list[Entry], options: Options) -> list[str]:
    parts = pieces(entries, options)
    turns = sum(
        1
        for entry in entries
        if entry.role == "user"
        for block in entry.blocks
        if (isinstance(block, Prose) and block.kind == "prose") or image_opens_turn(entry, block)
    )
    started = next((entry.at for entry in entries if entry.at is not None), None)
    head = heading(options, started, turns)

    frame = length(head) + length(options.session_id or "") + WRAPPER_OVERHEAD
    budget = max(options.max_chars - frame, 1_000)
    groups: list[list[str]] = [[]]
    size = 0
    for piece in parts:
        if length(piece) > budget:
            piece = clipped(piece, budget - CLIP_NOTE)
        count = length(piece)
        if size > 0 and size + count + 2 > budget:
            groups.append([])
            size = 0
        groups[-1].append(piece)
        size += count + 2

    out = []
    for index, group in enumerate(groups):
        part = f" (part {index + 1} of {len(groups)})" if len(groups) > 1 else ""
        marker = (
            f"<!-- dex-conversation {options.session_id or ''} "
            f"part {index + 1} of {len(groups)} -->"
        )
        body = "\n\n".join(group)
        out.append(
            f"{marker}\n<details>\n<summary>{head}{part}</summary>\n\n{body}\n\n</details>"
        )
    return out


def heading(options: Options, started, turns: int) -> str:
    parts = ["<b>Conversation</b>"]
    if options.title:
        parts.append(escaped(options.title))
    if started is not None:
        local = started.astimezone()
        parts.append(f"{local.day} {MONTHS[local.month - 1]} {local.year}")
    parts.append("1 turn" if turns == 1 else f"{turns} turns")
    if options.session_id:
        parts.append(f"<code>{options.session_id[:8]}</code>")
    return " · ".join(parts)


def agent_purposes(entries: list[Entry]) -> dict[str, str]:
    purposes = {}
    for entry in entries:
        for block in entry.blocks:
            if isinstance(block, ToolCall) and block.is_delegation and block.agent_id:
                if block.purpose is not None:
                    purposes[block.agent_id] = block.purpose
    return purposes


def pieces(entries: list[Entry], options: Options) -> list[str]:
    out: list[str] = []
    calls: list[ToolCall] = []
    agents = agent_purposes(entries)

    def flush():
        nonlocal calls
        if calls:
            out.append(tool_line(calls))
        calls = []

    for entry in entries:
        for block in entry.blocks:
            if isinstance(block, Prose) and block.kind == "thinking":
                continue
            if isinstance(block, ToolCall):
                if block.is_question:
                    flush()
                    out.append(question(block, options))
                elif block.is_plan:
                    flush()
                    out.append(plan(block, options))
                else:
                    calls.append(block)
                continue
            if isinstance(block, Prose) and block.kind == "prose":
                flush()
                speaker = options.assistant if entry.role == "assistant" else options.author
                out.append(spoken(speaker, block.text))
                continue
            if isinstance(block, Prose) and block.kind == "narration":
                flush()
                out.append(f"*{escaped(block.text)}*")
                continue
            if isinstance(block, Image):
                flush()
                line = f"<sub>{escaped(block.label)}</sub>"
                if image_opens_turn(entry, block):
                    line = f"**{options.author}:** {line}"
                out.append(line)
                continue
            if isinstance(block, Notice):
                flush()
                mark = "⚠️ " if block.is_error else ""
                out.append(quoted(mark + "*" + escaped(block.text) + "*"))
                continue
            if isinstance(block, PeerMessage):
                flush()
                name = block.name or "another session"
                agent = agents.get(block.address) if block.address else None
                if block.direction == "inbound" and agent is not None:
                    out.append(spoken(f"{agent} (agent)", block.body))
                elif block.direction == "inbound":
                    out.append(spoken(f"{name} (another session)", block.body))
                else:
                    out.append(spoken(f"{options.assistant} → {name}", block.body))
                continue
            if isinstance(block, Compaction):
                flush()
                out.append(compaction_line(block))
    flush()
    return out


def spoken(speaker: str, text: str) -> str:
    body = escaped(text.strip(WHITESPACE))
    if not body:
        return f"**{speaker}:**"
    return f"**{speaker}:** {body}" if fits_inline(body) else f"**{speaker}:**\n\n{body}"


def _is_number(character: str) -> bool:
    return unicodedata.category(character) in ("Nd", "Nl", "No")


def fits_inline(body: str) -> bool:
    if "\n" in body:
        return False
    if not body:
        return True
    first = body[0]
    if first in "#->|*+`":
        return False
    if _is_number(first):
        for character in body:
            if not _is_number(character):
                return character != "."
    return True


def tool_line(calls: list[ToolCall]) -> str:
    pieces = []
    stretch: list[ToolCall] = []

    def close():
        if len(stretch) == 1:
            pieces.append(describe(stretch[0]))
        elif stretch:
            lost = any(call.is_pending or call.result.is_unrecorded for call in stretch)
            tally = f"{len(stretch)} calls · never came back" if lost else f"{len(stretch)} calls"
            pieces.append(f"{inline_escaped(run_sentence(stretch))} · {tally}")
        stretch.clear()

    for call in calls:
        if call.is_delegation:
            close()
            pieces.append(describe(call))
        else:
            stretch.append(call)
    close()
    return "<sub>" + " · ".join(pieces) + "</sub>"


def inline_escaped(text: str) -> str:
    """Plain text that reads as itself inside markdown: `**/*.swift` and `__init__.py` aren't emphasis."""
    out = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return re.sub(r"([\\`*_\[\]~|])", r"\\\1", out)


# RunSentence.swift builds the same sentence; keep the two in step.
COMMAND_LIMIT = 40


# PastTense.swift has the same lists; keep the two in step.
IRREGULAR_PAST = {
    "drive": "drove", "hide": "hid", "unhide": "unhid", "shrink": "shrank", "sweep": "swept",
    "fit": "fit",
    "read": "read", "reread": "reread", "find": "found", "run": "ran", "rerun": "reran",
    "build": "built", "rebuild": "rebuilt", "see": "saw", "get": "got", "make": "made",
    "write": "wrote", "rewrite": "rewrote", "give": "gave", "set": "set", "reset": "reset",
    "quit": "quit", "break": "broke", "bring": "brought", "teach": "taught", "split": "split",
    "keep": "kept", "draw": "drew", "redraw": "redrew", "put": "put", "let": "let",
    "hold": "held", "send": "sent", "resend": "resent", "cut": "cut", "catch": "caught",
    "take": "took", "do": "did", "redo": "redid", "undo": "undid", "go": "went",
    "begin": "began", "choose": "chose", "tell": "told", "think": "thought", "lead": "led",
    "feed": "fed", "leave": "left", "spin": "spun", "shut": "shut", "hit": "hit",
    "seek": "sought", "understand": "understood",
}

DOUBLED_PAST = {
    "cat", "crop", "debug", "defer", "skim", "format", "reformat",
    "chop", "commit", "drop", "flag", "grep", "jog", "log", "map", "nag", "pin", "plan",
    "plug", "prep", "recommit", "remap", "repin", "rescan", "retag", "scan", "ship", "skip",
    "snip", "step", "stop", "strip", "stub", "submit", "swap", "tag", "trim", "unplug",
    "unwrap", "unzip", "wrap", "zip",
}

REGULAR_PAST = DOUBLED_PAST | {
    "accept", "add", "aggregate", "align", "allow", "amend", "animate", "apply", "archive",
    "ask", "assemble", "assert", "attach", "audit", "boot", "bump", "bundle", "calculate",
    "call", "capture", "carry", "cat", "change", "check", "checkout", "checkpoint", "chmod",
    "classify", "clean", "clear", "click", "clone", "close", "collect", "combine", "commit",
    "compare", "compile", "compute", "confirm", "copy", "correct", "count", "cover", "create",
    "crop", "debug", "decode", "dedupe", "defer", "delete", "deploy", "describe", "detach",
    "diff", "disable", "discard", "distinguish", "document", "download", "draft",
    "dump", "echo", "edit", "enable", "encode", "ensure", "enumerate", "erase", "escape",
    "examine", "exclude", "exercise", "explain", "explore", "export", "expose", "extend",
    "extract", "fetch", "filter", "finish", "fix", "focus", "fold", "format", "forward",
    "gate", "gather", "generate", "guard", "hand", "handle", "identify", "import",
    "index", "ingest", "inline", "insert", "inspect", "install", "instrument", "invalidate",
    "invoke", "kick", "kill", "label", "land", "launch", "lengthen", "limit", "link", "lint",
    "list", "load", "locate", "lock", "look", "loosen", "mark", "measure", "mention", "merge",
    "mirror", "mount", "move", "name", "narrow", "normalise", "normalize", "notarize", "note",
    "number", "open", "orient", "outline", "package", "parse", "pass", "patch", "peek", "pick",
    "point", "port", "post", "prefix", "press", "preview", "print", "probe", "profile",
    "prototype", "prune", "pull", "push", "query", "queue", "raise", "rank", "readd",
    "realign", "reapply", "rebase", "reboot", "recapture", "recheck", "recompile", "reconcile",
    "record", "recreate", "rediff", "reduce", "refactor", "refine", "reformat", "refresh",
    "regenerate", "register", "reindex", "reinstall", "relabel", "relaunch", "release",
    "reload", "remeasure", "remove", "rename", "render", "reopen", "repeat", "replace",
    "replay", "report", "reproduce", "reprofile", "rerender", "resize", "resolve", "restart",
    "restore", "restrict", "restructure", "restyle", "retest", "retry", "reuse", "revert",
    "review", "rewire", "rework", "route", "sample", "save", "scroll", "search", "seed",
    "select", "settle", "shorten", "show", "sign", "simplify", "simulate", "size",
    "skim", "snapshot", "sort", "squash", "stack", "stage", "stamp", "start", "store",
    "stress", "summarise", "summarize", "survey", "swap", "switch", "sync", "tail",
    "test", "thread", "tidy", "tighten", "time", "toggle", "touch", "trace", "treat",
    "trigger", "try", "turn", "type", "typecheck", "unfold", "uninstall", "unlink",
    "unlock", "unregister", "unstage", "update", "upload", "use", "validate", "verify", "view",
    "wait", "walk", "watch", "widen", "wire", "zoom",
}

# Past the opening, these are more often a thing named: "Show status, diff and log".
MOSTLY_NOUNS = {
    "store", "log", "diff", "index", "sample", "record", "report", "stack", "tag", "snapshot",
    "profile",
}


def past_tense(clause: str) -> str:
    """"Commit, merge and push" as "Committed, merged and pushed": the opening word and one after "and", "then" or a comma, when a known verb."""
    words = clause.split(" ")
    for index, word in enumerate(words):
        if index > 0 and words[index - 1] not in ("and", "then") and not words[index - 1].endswith(","):
            continue
        bare = word.rstrip(",.:;")
        if index > 0 and bare.lower() in MOSTLY_NOUNS:
            continue
        turned = _turned(bare)
        if turned is not None:
            words[index] = turned + word[len(bare):]
    return " ".join(words)


def _turned(word: str) -> str | None:
    lower = word.lower()
    past = _past_of(lower)
    if past is None and "-" in lower:
        head, _, last = lower.rpartition("-")
        turned = _past_of(last)
        past = f"{head}-{turned}" if turned is not None else None
    if past is None:
        return None
    return past[:1].upper() + past[1:] if word[:1].isupper() else past


def _past_of(verb: str) -> str | None:
    if verb in IRREGULAR_PAST:
        return IRREGULAR_PAST[verb]
    if verb not in REGULAR_PAST:
        return None
    if verb in DOUBLED_PAST:
        return verb + verb[-1] + "ed"
    if verb.endswith("e"):
        return verb + "d"
    if verb.endswith("y") and len(verb) > 1 and verb[-2] not in "aeiou":
        return verb[:-1] + "ied"
    return verb + "ed"

def _clause_case(text: str) -> str:
    """"Run tests" → "run tests", but "CI logs" stays."""
    if len(text) > 1 and text[1].isupper():
        return text
    return text[:1].lower() + text[1:]


class _Clause:
    def __init__(self, verb: str):
        self.verb = verb
        self.things: list[str] = []
        self.failed: set[str] = set()
        self.failures = 0
        self.dropped: set[str] = set()
        self.drops = 0

    def said(self) -> str:
        def marked(thing: str) -> str:
            if thing in self.dropped:
                return f"{thing} ({DROPPED_NOTE})"
            return f"{thing} (failed)" if thing in self.failed else thing

        counts = [f"{self.failures} failed"] if self.failures else []
        if self.drops:
            counts.append(f"{self.drops} {DROPPED_NOTE}")
        tally = f" ({', '.join(counts)})" if counts else ""
        things = self.things
        if not things:
            listed = "(failed)" if self.failures else None
        elif len(things) == 1:
            listed = marked(things[0])
        elif len(things) == 2:
            joiner = ", " if not self.verb else " and "
            listed = marked(things[0]) + joiner + marked(things[1])
        elif not self.verb:
            listed = f"{things[0]} and {len(things) - 1} more commands{tally}"
        else:
            listed = f"{things[0]} and {len(things) - 1} others{tally}"
        return " ".join(word for word in (self.verb, listed) if word)


def run_sentence(calls: list[ToolCall]) -> str:
    clauses: list[_Clause] = []
    for call in calls:
        verb, thing = run_phrase(call)
        failed = call.result is not None and call.result.is_error and not call.result.is_unrecorded
        if not clauses or clauses[-1].verb != verb:
            clauses.append(_Clause(verb))
        clause = clauses[-1]
        if failed:
            clause.failures += 1
        if call.was_dropped:
            clause.drops += 1
        if thing is None:
            continue
        if thing not in clause.things:
            clause.things.append(thing)
        if failed:
            clause.failed.add(thing)
        if call.was_dropped:
            clause.dropped.add(thing)
    sentence = ", ".join(clause.said() for clause in clauses)
    return sentence[:1].upper() + sentence[1:]


def run_phrase(call: ToolCall) -> tuple[str, str | None]:
    name = call.name
    if name == "Read":
        return "read", _file_name(call)
    if name in ("Edit", "MultiEdit", "NotebookEdit"):
        return "edited", _file_name(call)
    if name == "Write":
        return "wrote", _file_name(call)
    if name == "Grep":
        return "searched for", _quoted(call.argument("pattern"))
    if name == "Glob":
        return "looked for", _quoted(call.argument("pattern"))
    if name == "Bash":
        return _command_phrase(call)
    if name == "BashOutput":
        return "checked", "a shell"
    if name == "WebFetch":
        url = call.argument("url")
        return "fetched", _host(url) if url else None
    if name == "WebSearch":
        return "searched the web for", _quoted(call.argument("query"))
    if name == "Skill":
        skill = call.argument("skill") or call.argument("command")
        return "ran", f"/{skill}" if skill else None
    if name == "ToolSearch":
        return "loaded", "tools"
    if name == "Monitor":
        return "watched", call.argument("description")
    parts = name.split("__")
    if len(parts) >= 3 and parts[0] == "mcp":
        return "called", f"{'__'.join(parts[2:])} ({parts[1]})"
    return "used", name


def _host(url: str) -> str:
    """As Swift's `URL.host` has it: case kept, port off, and the URL itself where it won't parse."""
    try:
        netloc = urllib.parse.urlsplit(url).netloc
    except ValueError:
        return url
    host = netloc.rsplit("@", 1)[-1]
    if not host.startswith("["):
        host = host.split(":", 1)[0]
    return host or url


def _file_name(call: ToolCall) -> str | None:
    path = call.argument("file_path") or call.argument("notebook_path")
    return os.path.basename(path) if path else None


def _quoted(text: str | None) -> str | None:
    if text is None:
        return None
    return f"“{prefix(text, COMMAND_LIMIT) + '…' if length(text) > COMMAND_LIMIT else text}”"


def _command_phrase(call: ToolCall) -> tuple[str, str | None]:
    description = call.argument("description")
    if description is not None:
        description = _clause_case(past_tense(description))
    command = call.argument("command")
    if command is None:
        return ("", description) if description is not None else ("ran", None)
    typed = command.strip(WHITESPACE)
    line = typed.split("\n")[0]
    if line.startswith("cd ") and "&& " in line:
        line = line[line.index("&& ") + 3:]
    if length(line) <= COMMAND_LIMIT and ("\n" not in typed or description is None):
        return "ran", line
    if description is not None:
        return "", description
    return "ran", prefix(line, COMMAND_LIMIT) + "…"


def describe(call: ToolCall) -> str:
    if call.is_delegation:
        line = "Agent"
        purpose = call.purpose
        if purpose is not None:
            line += " " + code(purpose)
        if call.result is not None and call.result.subagent is not None:
            line += f" ({call.result.subagent.summary})"
    else:
        line = call.name
        summary = call.summary
        if summary is not None:
            line += " " + code(summary)
    unrecorded = call.result is not None and call.result.is_unrecorded
    if call.result is not None and call.result.is_error and not unrecorded:
        line += " ✗"
    if call.was_dropped:
        line += f" ({DROPPED_NOTE})"
    if call.is_pending or unrecorded:
        line += " …"
    return line


def question(call: ToolCall, options: Options) -> str:
    asked = call.asked_questions
    lines = [f"**{options.assistant} asked:**"]
    for item in asked:
        line = "- " + escaped(item.question)
        if item.answer:
            line += f" → **{escaped(item.answer)}**"
            if item.note:
                line += f" *({escaped(item.note)})*"
        lines.append(line)
    if call.result is not None and all(item.answer is None for item in asked):
        lines.append("")
        lines.append(spoken(options.author, call.result.response or call.result.text))
    return "\n".join(lines)


def plan(call: ToolCall, options: Options) -> str:
    kind, detail = call.plan_outcome
    if kind == "waiting":
        outcome = "awaiting approval"
    elif kind == "approved":
        outcome = "approved with edits" if detail else "approved"
    else:
        outcome = f"rejected: {escaped(detail)}" if detail is not None else "rejected"
    lines = [f"**{options.assistant} proposed a plan** ({outcome})"]
    proposed = call.proposed_plan
    if proposed is not None:
        lines.append("")
        lines.append(quoted(escaped(proposed)))
    return "\n".join(lines)


def compaction_line(compaction: Compaction) -> str:
    words = ["Compacted"]
    if compaction.trigger is not None:
        words[0] += f" ({compaction.trigger})"
    if compaction.pre_tokens is not None and compaction.post_tokens is not None:
        words.append(f"{compaction.pre_tokens} → {compaction.post_tokens} tokens")
    return "---\n*" + ": ".join(words) + "*\n---"


def quoted(text: str) -> str:
    return "\n".join("> " + line for line in text.split("\n"))


def code(text: str) -> str:
    flat = escaped(text.replace("\n", " "))
    return flat if "`" in flat else f"`{flat}`"


# ------------------------------------------------------------ reading the file

def config_directory() -> str:
    override = os.environ.get("CLAUDE_CONFIG_DIR")
    if override:
        return os.path.expanduser(override).rstrip("/") or "/"
    return os.path.join(os.path.expanduser("~"), ".claude")


def locate(session_id: str) -> str | None:
    if not session_id:
        return None
    projects = os.path.join(config_directory(), "projects")
    try:
        names = os.listdir(projects)
    except OSError:
        return None
    best = None
    best_time = float("-inf")
    for name in sorted(names):
        if name.startswith("."):
            continue
        candidate = os.path.join(projects, name, f"{session_id}.jsonl")
        if not os.path.exists(candidate):
            continue
        try:
            written = os.stat(candidate).st_mtime
        except OSError:
            written = float("-inf")
        if best is None or written > best_time:
            best, best_time = candidate, written
    return best


def complete_lines(data: bytes) -> list[bytes]:
    last = data.rfind(b"\n")
    if last < 0:
        return []
    return [line for line in data[: last + 1].split(b"\n") if line]


def read_document(path: str) -> Document:
    document = Document()
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError:
        return document
    for line in complete_lines(data):
        document.append_line(line)
    return document


DIGEST_WINDOWS = [256_000, 4_000_000]


def digest_title(path: str) -> str | None:
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    if size == 0:
        return None
    try:
        handle = open(path, "rb")
    except OSError:
        return None
    with handle:
        for window in DIGEST_WINDOWS:
            start = size - window if size > window else 0
            handle.seek(start)
            data = handle.read()
            lines = [line for line in data.split(b"\n") if line]
            if start != 0 and lines:
                lines = lines[1:]
            title, read_anything = _title_in(lines)
            if read_anything:
                return title
            if start == 0:
                break
    return None


def _title_in(lines: list[bytes]) -> tuple[str | None, bool]:
    read_anything = False
    ai_title = None
    for line in reversed(lines):
        record = decode_record(line)
        if record is None:
            continue
        read_anything = True
        if record.custom_title:
            return record.custom_title, True
        if ai_title is None and record.ai_title:
            ai_title = record.ai_title
    return ai_title, read_anything


# ------------------------------------------------------------------------ main

USAGE = f"""usage: {os.path.basename(sys.argv[0])} <session-id | transcript.jsonl> ... \
[--author NAME] [--out DIR] [--max-chars N] [--title TEXT]

Renders a session's conversation as a collapsed markdown block for a pull
request body. With --out, writes one file per part (a part fits under
--max-chars, default 60000) and prints the paths; without it, prints to stdout."""


def fail(message: str, code: int = 1):
    sys.stderr.write(message + "\n")
    sys.exit(code)


def main(argv: list[str]) -> None:
    targets: list[str] = []
    author = "User"
    out_directory = None
    max_chars = 60_000
    title = None

    arguments = list(argv)
    while arguments:
        argument = arguments.pop(0)

        def value():
            if not arguments:
                fail(f"{argument} needs a value\n\n{USAGE}", 2)
            return arguments.pop(0)

        if argument == "--author":
            author = value()
        elif argument == "--out":
            out_directory = value()
        elif argument == "--title":
            title = value()
        elif argument == "--max-chars":
            given = value()
            try:
                max_chars = int(given, 10)
            except ValueError:
                fail("--max-chars needs a positive number", 2)
            if max_chars <= 0:
                fail("--max-chars needs a positive number", 2)
        elif argument in ("-h", "--help"):
            print(USAGE)
            sys.exit(0)
        elif argument.startswith("-"):
            fail(f"unknown option {argument}\n\n{USAGE}", 2)
        else:
            targets.append(argument)

    if not targets:
        fail(USAGE, 2)

    for target in targets:
        if os.path.exists(target):
            path = os.path.abspath(target)
        else:
            found = locate(target)
            if found is None:
                fail(f"no transcript found for {target} under {config_directory()}")
            path = found

        document = read_document(path)
        if document.is_empty:
            fail(f"{path} holds no conversation")

        session_id = os.path.splitext(os.path.basename(path))[0]
        options = Options(
            author=author,
            title=title if title is not None else digest_title(path),
            session_id=session_id,
            max_chars=max_chars,
        )
        parts = render(document.entries, options)

        if out_directory is not None:
            directory = os.path.abspath(out_directory)
            try:
                os.makedirs(directory, exist_ok=True)
            except OSError:
                pass
            for index, part in enumerate(parts):
                file = os.path.join(directory, f"{session_id[:8]}-{index + 1}.md")
                try:
                    with open(file, "w", encoding="utf-8") as handle:
                        handle.write(part)
                except OSError as error:
                    fail(f"could not write {file}: {error}")
                print(file)
        else:
            print("\n\n".join(parts))


if __name__ == "__main__":
    main(sys.argv[1:])
