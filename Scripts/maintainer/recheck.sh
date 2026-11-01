#!/bin/bash
# Re-run every probe and say which readings the CLI has moved past.
#
# The readings in docs/claude-code are observed behaviour, and none of it was ever
# announced — the changelog cannot warn you that any of it changed, which is
# why `changelog-watch.py` reads it for things to build rather than for things
# that broke. The probes are the warning, and until this script they had no
# trigger: the version moved on every build and nothing re-ran them, so a
# reading stayed pinned at whatever release last had a person's attention.
#
# `make-app.sh` calls this when the SDK pin actually moves, which is the moment
# the CLI our sessions run becomes a different one. That is rare, so this being
# slow is the right trade — it drives a dozen real sessions and takes minutes.
#
# Three of the probes rewrite a source file. Those run for real only on a clean
# `main`, and `--dry-run` everywhere else: a build that edits tracked source in
# the middle of somebody's feature branch is the surprise `make-app.sh` already
# refuses to spring when it declines to commit the pin off `main`.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIDECAR="$ROOT/Sidecar"

# Long enough for a real session to start, answer and be reaped; short enough
# that an auth prompt nobody is there to answer doesn't hang a build all night.
# The floor is set by the slowest honest probe rather than by taste:
# `queued-message-probe` drives a TUI through two whole turns, and
# `host-death-probe` waits out a 90s command on purpose.
TIMEOUT="${RECHECK_TIMEOUT:-600}"

FORCE_DRY=""
[ "${1:-}" = "--dry-run" ] && FORCE_DRY=yes

# A record per run: the pipe the app reads is thrown away, and a red run used to leave nothing.
RECHECK_DIR="${DEX_RECHECK_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dex/recheck}"
RUN_DIR="$RECHECK_DIR/$(date +%Y-%m-%d-%H%M%S)"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$RUN_DIR"
# Only run folders: DEX_RECHECK_DIR can point anywhere.
ls -1d "$RECHECK_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]/ 2>/dev/null | sort -r | tail -n +21 | while IFS= read -r old; do
    rm -rf "$old"
done
# The run is a function piped through tee rather than exec'd into one: the pipe is
# waited for, so a red exit cannot outrun the tail of its own record.
main() {
PASSED=(); FAILED=(); SKIPPED=()

commas() { local out="" n; for n in "$@"; do out="$out${out:+, }$n"; done; printf '%s' "$out"; }
quoted() { local out="" n; for n in "$@"; do out="$out${out:+, }\"$n\""; done; printf '[%s]' "$out"; }

# Written out rather than shelled to `timeout`, which macOS does not ship: the
# guard is the whole reason an unattended build can run these at all, and one
# that quietly isn't there on the only platform this app runs on is worse than
# none — it reads as guarded right up until a probe waits all night.
wait_for() {
    local secs="$1" log="$2"; shift 2
    "$@" >"$log" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            # TERM first: a probe holding a session should get the chance to
            # close it, and the ones that don't take the hint get KILL.
            kill -TERM "$pid" 2>/dev/null
            sleep 2
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

# Numbered against the whole plan, so a reader that sees `resume-probe` on
# its own — the app's toast, a terminal glanced at — knows there are nine
# more behind it. The plan is what makes that count honest: every probe is
# decided on (run or skipped) before the first one starts, so the total
# never grows under the person watching it. The name is printed before the
# probe runs and the verdict lands on the same line after it, which is why
# whoever reads this as a stream has to read partial lines.
run() {
    local name="$1"; shift
    DONE=$((DONE + 1))
    printf '  %d/%d %-34s' "$DONE" "$TOTAL" "$name"
    local log="$RUN_DIR/$name.log"
    wait_for "$TIMEOUT" "$log" "$@"
    local status=$?
    if [ "$status" -eq 0 ]; then
        echo "ok"
        PASSED+=("$name")
    elif [ "$status" -eq 77 ]; then
        echo "skipped — $(tail -1 "$log")"
        SKIPPED+=("$name")
    else
        # 124 is the one worth telling apart: a probe that timed out was most
        # likely waiting on something no build has a person behind it to answer.
        [ "$status" -eq 124 ] && echo "timed out after ${TIMEOUT}s" || echo "FAILED ($status)"
        FAILED+=("$name")
        tail -12 "$log" | sed 's/^/      /'
    fi
}

skip() {
    printf '  %-34s%s\n' "$1" "skipped — $2"
    SKIPPED+=("$1")
}

# By file rather than `npm run`: package.json names only two thirds of them.
sidecar_probe() {
    local file="test/$1.ts"
    (cd "$SIDECAR" && node "$file")
}

script_path() {
    [ -e "$ROOT/Scripts/$1.py" ] && echo "$ROOT/Scripts/$1.py" || echo "$ROOT/Scripts/maintainer/$1.py"
}

# Asked of the tree rather than of the branch alone: a clean `main` is the only
# place a rewrite is nobody's surprise, and `main` with edits already in it is
# still somebody's work in progress.
DRY="--dry-run"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
PINNED_SOURCES=(
    Sources/DexCore/Actions/ModelAliases.swift
    Sources/DexCore/Actions/PermissionModes.swift
    Sources/DexCore/Composer/BuiltInCommands.swift
)
if [ -z "$FORCE_DRY" ] && [ "$BRANCH" = "main" ] &&
   [ -z "$(git -C "$ROOT" status --porcelain -- "${PINNED_SOURCES[@]}" 2>/dev/null)" ]; then
    DRY=""
fi
HAS_PYTE=""
python3 -c "import pyte" 2>/dev/null && HAS_PYTE=yes

echo "Re-running the probes."
echo

# Each step is `group:name`; the groups print their own heading as the plan
# reaches them, and decide how a name is run.
# Globbed: a list once ran 13 of 31 and said nothing about the rest.
STEPS=(); SKIP_SCRIPT=(); SKIP_REWRITE=()
REWRITERS=(slash-command-probe model-alias-probe permission-mode-probe)
if [ -d "$SIDECAR/node_modules" ]; then
    STEPS+=("sidecar:smoke")
    PROBES=("$SIDECAR"/test/*-probe.ts)
    for file in "${PROBES[@]}"; do
        [ -e "$file" ] || continue
        STEPS+=("sidecar:$(basename "$file" .ts)")
    done
fi
for file in "$ROOT"/Scripts/*-probe.py; do
    [ -e "$file" ] || continue
    name="$(basename "$file" .py)"
    case " ${REWRITERS[*]} " in *" $name "*) continue ;; esac
    # The import is what says a probe drives a terminal.
    if [ -z "$HAS_PYTE" ] && grep -q pyte "$file"; then
        SKIP_SCRIPT+=("$name")
        continue
    fi
    STEPS+=("script:$name")
done
# token-audit is an analysis tool rather than a probe, but a reading names it,
# and a reading's marker only means anything if the thing it names still runs.
STEPS+=("script:token-audit")
for name in "${REWRITERS[@]}"; do
    if [ -z "$HAS_PYTE" ] && grep -q pyte "$ROOT/Scripts/$name.py"; then
        SKIP_REWRITE+=("$name")
        continue
    fi
    STEPS+=("rewrite:$name")
done

TOTAL=${#STEPS[@]}
DONE=0
# Groups in a fixed order, each with its heading and its skips, whether or
# not any of its steps made the plan — a group with nothing to run still
# says why, under its own heading.
for kind in sidecar script rewrite; do
    case "$kind" in
        sidecar) echo "Sidecar (drives real sessions through the SDK)"
                 [ -d "$SIDECAR/node_modules" ] || skip "all Sidecar probes" "no node_modules under Sidecar/" ;;
        script)  echo "Scripts (reads transcripts already on disk)"
                 for name in ${SKIP_SCRIPT[@]+"${SKIP_SCRIPT[@]}"}; do
                     skip "$name" "needs pip3 install pyte"
                 done ;;
        rewrite) if [ -z "$DRY" ]; then
                     echo "Rewriting probes (clean main — these edit source)"
                 else
                     echo "Rewriting probes (--dry-run: $([ -n "$FORCE_DRY" ] && echo "asked for" || echo "not a clean main"))"
                 fi
                 for name in ${SKIP_REWRITE[@]+"${SKIP_REWRITE[@]}"}; do
                     skip "$name" "needs pip3 install pyte"
                 done ;;
    esac
    for step in "${STEPS[@]}"; do
        [ "${step%%:*}" = "$kind" ] || continue
        name="${step#*:}"
        case "$kind" in
            sidecar) run "$name" sidecar_probe "$name" ;;
            script)  run "$name" python3 "$(script_path "$name")" ;;
            rewrite) run "$name" python3 "$ROOT/Scripts/$name.py" $DRY ;;
        esac
    done
    echo
done

LISTS="dry-run"
if [ -z "$DRY" ]; then
    LISTS="unchanged"
    CHANGED="$(git -C "$ROOT" status --porcelain -- "${PINNED_SOURCES[@]}" 2>/dev/null)"
    if [ -n "$CHANGED" ]; then
        LISTS="left-uncommitted"
        if [ "$LISTS" = left-uncommitted ]; then
            echo "The CLI moved under $(commas $(echo "$CHANGED" | awk '{print $NF}' | xargs -n1 basename)): rewritten to match, left uncommitted."
        fi
        echo
    fi
fi

# The point of the whole exercise: a probe that passed says the behaviour still
# holds, and the reading's marker is what carries that to the next person.
echo "Readings still pinned below the CLI that answers for them:"
# Its first two lines name the two `claude` binaries; the record below reads them.
WATCH="$(python3 "$ROOT/Scripts/maintainer/changelog-watch.py" --probes 2>&1)"
echo "$WATCH" | sed -n '3,$p' | sed 's/^/  /'
INSTALLED_CLI="$(echo "$WATCH" | sed -n '1s/^claude \([0-9][0-9.]*\) installed.*/\1/p')"
BUNDLED_CLI="$(echo "$WATCH" | sed -n '2s/^claude \([0-9][0-9.]*\) in the SDK.*/\1/p')"

# What a later session reads when it finds the three lists dirty on main.
cat > "$RECHECK_DIR/last.json" <<JSON
{
  "started": "$STARTED",
  "finished": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cli_installed": $([ -n "$INSTALLED_CLI" ] && echo "\"$INSTALLED_CLI\"" || echo null),
  "cli_bundled": $([ -n "$BUNDLED_CLI" ] && echo "\"$BUNDLED_CLI\"" || echo null),
  "passed": $(quoted ${PASSED[@]+"${PASSED[@]}"}),
  "failed": $(quoted ${FAILED[@]+"${FAILED[@]}"}),
  "skipped": $(quoted ${SKIPPED[@]+"${SKIPPED[@]}"}),
  "dry_run": $([ -n "$DRY" ] && echo true || echo false),
  "lists": "$LISTS",
  "dir": "$RUN_DIR"
}
JSON

echo
echo "${#PASSED[@]} passed, ${#FAILED[@]} failed, ${#SKIPPED[@]} skipped — the run is in $RUN_DIR."
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "A failing probe is a reading that no longer holds, or a probe that has"
    echo "rotted — either way a reading in docs/claude-code is now untrue. Fix it"
    echo "before the pin it carries goes out in a build."
    exit 1
fi
echo "Every probe that ran still holds. Re-pin the (CLI vX.Y.Z) markers in docs/claude-code."
}

main 2>&1 | tee "$RUN_DIR/run.log"
exit "${PIPESTATUS[0]}"
