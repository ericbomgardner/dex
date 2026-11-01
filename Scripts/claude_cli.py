"""The `claude` a probe runs, and the credential its sessions run on.

The app's sessions run the CLI the SDK ships, not the one on PATH, so that is
the one a probe measures (docs/claude-code/which-cli-the-apps-sessions-run.md).
"""

import atexit
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CREDENTIALS = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN")
# Sidecar/test/credential.ts's SKIPPED, which recheck.sh counts as skipped.
SKIPPED = 77


def bundled_cli():
    found = sorted(glob.glob(os.path.join(
        ROOT, "Sidecar", "node_modules", "@anthropic-ai", "claude-agent-sdk-darwin-*", "claude")))
    if not found:
        sys.exit("no bundled claude under Sidecar/node_modules; run (cd Sidecar && npm install)")
    return found[0]


def keyed(env, probe):
    """Returns the environment and extra arguments a session started from here runs with.

    On an API key, the way the host runs one: through `apiKeyHelper` reading a
    file of the user's own, with no key in the environment, which also keeps an
    interactive session from stopping to ask whether to use it.
    """
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        print(f"{probe}: set ANTHROPIC_API_KEY; its sessions run on it", file=sys.stderr)
        sys.exit(2)
    folder = tempfile.mkdtemp(prefix="dex-probe-key-")
    atexit.register(shutil.rmtree, folder, True)
    path = os.path.join(folder, "key")
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as handle:
        handle.write(key + "\n")
    env = {k: v for k, v in env.items() if k not in CREDENTIALS}
    return env, ["--settings", json.dumps({"apiKeyHelper": f"/bin/cat '{path}'"})]


def on_login(env, probe):
    """Returns the environment for a probe whose reading is what a claude.ai login sees.

    Skips, rather than fails, on a machine with no such login stored.
    """
    env = {k: v for k, v in env.items() if k not in CREDENTIALS}
    status = subprocess.run([bundled_cli(), "auth", "status", "--json"], env=env,
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
    try:
        login = json.loads(status.stdout)
    except ValueError:
        login = {}
    if login.get("loggedIn") is not True or login.get("authMethod") != "claude.ai":
        print(f"skipped: {probe} reads what a claude.ai login sees, and none is stored")
        sys.exit(SKIPPED)
    return env
