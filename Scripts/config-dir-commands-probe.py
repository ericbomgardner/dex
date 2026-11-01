#!/usr/bin/env python3
"""Checks where the CLI reads user commands and skills from under CLAUDE_CONFIG_DIR.

Builds a fake HOME with `.claude/commands` and `.claude/skills`, and a separate
config dir with its own, then reads `slash_commands` off `system/init` with the
variable set and unset. Init arrives before any request, so no login is needed;
a fake API key keeps the CLI off the real keychain. Nothing under the real
`~/.claude` is read or written.

Usage:  python3 Scripts/config-dir-commands-probe.py [path-to-claude]
"""

import json
import os
import subprocess
import sys
import tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from claude_cli import bundled_cli


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def seed(root, tag):
    write(os.path.join(root, "commands", f"{tag}cmd.md"), f"{tag} command\n")
    write(os.path.join(root, "skills", f"{tag}skill", "SKILL.md"),
          f"---\ndescription: {tag} skill\n---\nbody\n")


def init_commands(cli, env, cwd):
    out = subprocess.run(
        [cli, "-p", "--output-format", "stream-json", "--verbose", "hi"],
        env=env, cwd=cwd, stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=60)
    for line in out.stdout.splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("type") == "system" and record.get("subtype") == "init":
            return set(record.get("slash_commands") or []), record.get("claude_code_version")
    sys.exit(f"no init record\nstdout: {out.stdout[:500]}\nstderr: {out.stderr[:500]}")


def main():
    cli = sys.argv[1] if len(sys.argv) > 1 else bundled_cli()
    scratch = tempfile.mkdtemp(prefix="config-dir-probe-")
    home = os.path.join(scratch, "home")
    config = os.path.join(scratch, "config")
    project = os.path.join(scratch, "project")
    seed(os.path.join(home, ".claude"), "home")
    seed(config, "config")
    seed(os.path.join(project, ".claude"), "project")

    base = {k: v for k, v in os.environ.items() if k != "CLAUDE_CONFIG_DIR"}
    base.update(HOME=home, ANTHROPIC_API_KEY="sk-ant-probe-not-a-key")

    names = ["homecmd", "homeskill", "configcmd", "configskill", "projectcmd", "projectskill"]
    expected = {
        "unset": {"homecmd", "homeskill", "projectcmd", "projectskill"},
        "set": {"configcmd", "configskill", "projectcmd", "projectskill"},
    }

    failed = False
    for label, env in [("unset", base), ("set", {**base, "CLAUDE_CONFIG_DIR": config})]:
        commands, version = init_commands(cli, env, project)
        seen = {n for n in names if n in commands}
        ok = seen == expected[label]
        failed |= not ok
        print(f"CLI {version}, CLAUDE_CONFIG_DIR {label}: {sorted(seen)}"
              f" {'ok' if ok else 'expected ' + str(sorted(expected[label]))}")

    if failed:
        sys.exit("FAIL: user commands and skills no longer come from the config dir alone")
    print("PASS: with CLAUDE_CONFIG_DIR set, ~/.claude's commands and skills are not read")


if __name__ == "__main__":
    main()
