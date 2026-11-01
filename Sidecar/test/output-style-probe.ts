/**
 * Whether a session's output style and effort can be set when it starts and
 * moved while it runs.
 *
 *   node test/output-style-probe.ts
 *
 * The composer picks both for a new session and the pane's dial moves them on a
 * running one, which is the same shape the model and mode pickers already have.
 * Neither rests on anything documented as behaviour to rely on:
 *
 *  1. The **list** has to come from the CLI. Styles are files on disk — built
 *     in, under `~/.claude/output-styles`, and under a project's own — so a
 *     table in the app would name styles that aren't there and miss the ones
 *     that are. `initializationResult()` claims to answer with
 *     `available_output_styles` and the one in effect.
 *  2. `settings` at start has to actually reach the model, not just be recorded.
 *     Asking a session what style it is in settles nothing — it infers that from
 *     how it was told to write — so each style here carries a token invented for
 *     the run and the reading is whether the token comes back.
 *  3. `applyFlagSettings` has to move a session that is already going, and the
 *     turn after it has to be in the new style. This is the half a dial would
 *     be, and the half with no other way in: a style picked at start could be
 *     had by writing settings.json and never touching the SDK at all. It was
 *     measured as a refusal for a long time — accepted and silently ignored —
 *     and as of CLI v2.1.278 it moves the session for real, on the very next
 *     turn. The CLI's own word for that is the `system`/`init` it restates at
 *     the head of each turn — `initializationResult()` is the cached
 *     first-connect answer and stays on the style the session started at.
 *     Typing `/output-style` is answered too, where it was refused outright,
 *     though what it moves is a settings file rather than the session.
 *
 * Effort is read off `CLAUDE_EFFORT` rather than out of the reply. The SDK says
 * the resolved level is handed to Bash in that variable, which is the CLI's own
 * word for what the turn ran at — a model asked how hard it thought has nothing
 * to read either.
 *
 * The styles are written into the scratch directory's own `.claude/output-styles`
 * rather than the user's, so the probe adds nothing to a config that is under
 * version control. It also means `settingSources` must stay omitted, the way the
 * app leaves it: pass `[]` and the project's styles are not loaded and every
 * check here fails for a reason that has nothing to do with what it measures.
 */

import { query, resolveSettings } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-output-style-"));
const styles = path.join(scratch, ".claude", "output-styles");
mkdirSync(styles, { recursive: true });

/** Invented per run, so a marker in a reply can only have come from this run. */
const nonce = Math.floor(Math.random() * 1e9).toString(36).toUpperCase();
const ALPHA = `ALPHA-${nonce}`;
const BETA = `BETA-${nonce}`;

function writeStyle(name: string, marker: string): void {
  writeFileSync(
    path.join(styles, `${name}.md`),
    [
      "---",
      `name: ${name}`,
      `description: probe style ${marker}`,
      "keep-coding-instructions: true",
      "---",
      "",
      `End every single response with the exact token ${marker} on its own line.`,
      "Never write the other probe token. Keep replies to one short sentence.",
      "",
    ].join("\n"),
  );
}

writeStyle("probe-alpha", ALPHA);
writeStyle("probe-beta", BETA);

/**
 * Long enough to sit out the API's own retries: the run that found this spent
 * six minutes of its first turn on `api_error` backoff before a reply came.
 */
const LIMIT_MS = 600_000;

/**
 * A turn that ends without its `result`. Every reading after it would be taken
 * off the previous turn's messages — the first turn reads empty, the second
 * reads the first's marker with no `init` of its own — so the probe stops
 * rather than check anything against a stream that is one turn out.
 */
class Unfinished extends Error {}

/** An input stream that stays open until we let it go, as the host's does. */
function heldOpen(): {
  stream: AsyncGenerator<unknown>;
  send: (text: string) => void;
  close: () => void;
} {
  const queue: unknown[] = [];
  let wake: (() => void) | null = null;
  let closed = false;

  const push = (value: unknown) => {
    queue.push(value);
    wake?.();
  };

  async function* stream(): AsyncGenerator<unknown> {
    while (true) {
      if (queue.length > 0) {
        yield queue.shift();
        continue;
      }
      if (closed) return;
      await new Promise<void>((resolve) => {
        wake = () => {
          wake = null;
          resolve();
        };
      });
    }
  }

  return {
    stream: stream(),
    send: (text: string) =>
      push({ type: "user", message: { role: "user", content: text }, parent_tool_use_id: null }),
    close: () => {
      closed = true;
      wake?.();
    },
  };
}

/**
 * A session held open across several turns, handing back everything each turn
 * said. One turn is everything up to the `result` that ends it.
 */
function open(options: Record<string, unknown>): {
  session: any;
  turn: (text: string) => Promise<{ said: string; ran: string; style: string | null }>;
  close: () => void;
} {
  const input = heldOpen();
  const session: any = query({
    prompt: input.stream as any,
    options: {
      cwd: scratch,
      model: "sonnet",
      systemPrompt: { type: "preset", preset: "claude_code" },
      permissionMode: "bypassPermissions",
      ...options,
    } as any,
  });

  const iterator = (session as AsyncIterable<any>)[Symbol.asyncIterator]();

  async function turn(
    text: string,
  ): Promise<{ said: string; ran: string; style: string | null }> {
    input.send(text);
    const said: string[] = [];
    const ran: string[] = [];
    // The CLI restates its own `system`/`init` at the head of every turn, and
    // `output_style` is on it. That is the live reading: `initializationResult()`
    // hands back the *cached* first-connect response and never moves, however
    // far the session has been dialled since.
    let style: string | null = null;
    let finished = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const expired = new Promise<"expired">((resolve) => {
      timer = setTimeout(() => resolve("expired"), LIMIT_MS);
    });

    while (true) {
      const next = await Promise.race([iterator.next(), expired]);
      if (next === "expired" || next.done) break;
      const message = next.value;

      if (message.type === "system" && message.subtype === "api_error") {
        console.log(`  (api_error during ${JSON.stringify(text.slice(0, 40))}, the CLI is retrying)`);
      }

      if (message.type === "system" && typeof message.output_style === "string") {
        style = message.output_style;
      }

      if (message.type === "assistant") {
        for (const block of message.message?.content ?? []) {
          if (block?.type === "text") said.push(block.text);
        }
      }

      // Tool results come back as user turns; the effort reading is inside one.
      if (message.type === "user") {
        const content = message.message?.content;
        for (const block of Array.isArray(content) ? content : []) {
          if (block?.type !== "tool_result") continue;
          const inner = block.content;
          if (typeof inner === "string") ran.push(inner);
          else for (const part of inner ?? []) if (part?.type === "text") ran.push(part.text);
        }
      }

      if (message.type === "result") {
        finished = true;
        break;
      }
    }
    clearTimeout(timer);
    if (!finished) {
      throw new Unfinished(
        `the turn ${JSON.stringify(text.slice(0, 40))} got no result within ${LIMIT_MS / 1000}s, so every reading after it would be one turn out`,
      );
    }

    return { said: said.join("\n"), ran: ran.join("\n"), style };
  }

  return { session, turn, close: () => (input.close(), session.close?.()) };
}

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

/**
 * A reading worth printing that must not fail the run on its own. A style is an
 * instruction to a model rather than a filter on its output, so "the new marker
 * came back" measures compliance as much as it measures the setting. It is the
 * corroborating half; the hard checks beside it are the CLI's own books and the
 * *absence* of the old marker, neither of which the model can be sloppy about.
 */
function note(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "soft"}  ${description}`);
}

// ------------------------------------------------------------ output style

async function probeStyle(): Promise<void> {
  console.log("\noutput style");

  const run = open({ settings: { outputStyle: "probe-alpha" } });
  try {
    const first = await run.turn("Say hello.");

    let init: any = null;
    try {
      init = await run.session.initializationResult();
    } catch (error: any) {
      console.log(`  initializationResult threw: ${error?.message ?? error}`);
    }

    console.log(`  available: ${(init?.available_output_styles ?? []).join(", ") || "none listed"}`);
    console.log(`  in effect: ${init?.output_style ?? "not reported"}`);

    check(
      Array.isArray(init?.available_output_styles) && init.available_output_styles.length > 0,
      "the CLI lists the styles it has, so the picker needs no table of its own",
    );
    check(
      (init?.available_output_styles ?? []).includes("probe-alpha"),
      "a style the project supplies is in that list, not just the built-in ones",
    );
    check(
      init?.output_style === "probe-alpha",
      "the CLI names the style in effect, which is what a dial would show",
    );

    // What the app would rest on if it only ever set the style at start.
    check(
      first.said.includes(ALPHA),
      "a style named in `settings` reaches the model, not just the CLI's books",
    );

    // What the app can do about a style *after* it has started, which until CLI
    // v2.1.278 was nothing: `applyFlagSettings` took the style and dropped it,
    // so the app made it one pick in Settings and no dial anywhere. Every check
    // from here to the end of this function used to assert that refusal. They
    // now assert the move, so the probe fails the day it goes back — and the
    // app's one-pick-at-launch shape is the thing that reading is holding up.

    // The dial's own half: this is the only door into a session already going.
    let moveError: string | null = null;
    try {
      await run.session.applyFlagSettings({ outputStyle: "probe-beta" });
    } catch (error: any) {
      moveError = error?.message ?? String(error);
    }
    if (moveError) console.log(`  applyFlagSettings threw: ${moveError}`);
    check(moveError === null, "applyFlagSettings is accepted on a running session");

    // The hard reading is the CLI's own books, and *which* copy of them is the
    // whole care here. `initializationResult()` is documented as the cached
    // first-connect response and it never moves — it still said `probe-alpha`
    // on the run that measured this, with the model already writing BETA and
    // the CLI itself answering `Output style set to probe-alpha` a turn later.
    // Read as the live word it would report the move as a refusal, which is the
    // reading this probe exists to have stopped believing. The live word is the
    // `system`/`init` the CLI restates at the head of every turn.
    const second = await run.turn("Say hello again.");
    console.log(`  the turn after the move: ${second.style ?? "no init seen"}`);
    check(
      second.style === "probe-beta",
      "the CLI's own books moved with the call, on the very next turn",
    );

    let cached: any = null;
    try {
      cached = await run.session.initializationResult();
    } catch {
      // Printed as "not reported" below; nothing here hangs on it.
    }
    console.log(`  and initializationResult still says: ${cached?.output_style ?? "not reported"}`);
    note(
      cached?.output_style === "probe-alpha",
      "initializationResult is the cached first-connect answer and does not follow the move",
    );

    // The model's half, and the soft one. The assertion is the *absence* of the
    // old marker: a style is an instruction, not a filter, and a model asked to
    // say hello twice sometimes drops its trailing token — presence of a marker
    // failed about one run in three while measuring nothing. What cannot happen
    // while the style is still `probe-alpha` is a turn that never writes ALPHA,
    // since that style spells out writing it every time. Presence of BETA is
    // only noted, with one more turn spent on it before it is written off.
    let sawBeta = second.said.includes(BETA);
    check(
      second.said.length > 0 && !second.said.includes(ALPHA),
      "and the turn after the move is no longer written in the old style",
    );
    if (!sawBeta) {
      const third = await run.turn("Say hello once more.");
      console.log(`  a second turn to settle: ${third.said.includes(BETA) ? "BETA" : "neither marker"}`);
      sawBeta = third.said.includes(BETA);
    }
    note(sawBeta, "and the new style's own marker comes back, so the move reached the model");

    // The other route in, and the one the terminal uses. It used to be refused
    // outright (`/output-style isn't available in this environment`); now it
    // answers for real, and what it does is measured rather than read off the
    // answer — a command that replies politely and changes nothing is not a
    // route in.
    //
    // What it does is write the pick down, into the cwd's
    // `.claude/settings.local.json`, and the session it was typed at goes on
    // writing in the style it already had. That is the flag layer winning: this
    // session's style came from `settings` at launch and `applyFlagSettings`
    // above, both of which sit over every file, so the file the command just
    // wrote is outranked. Read as "the command is inert" it would be wrong —
    // nothing here says what it does to a session running with no style flag at
    // all, which the app has no way to start and so does not measure.
    const typed = await run.turn("/output-style probe-alpha");
    console.log(`  typing it back: ${typed.said.slice(0, 160).replace(/\n/g, " ") || "nothing said"}`);
    console.log(`  the turn it was typed in: ${typed.style ?? "no init seen"}`);
    check(
      !typed.said.includes("isn't available in this environment"),
      "the slash command is no longer refused as unavailable in this environment",
    );

    const settled = await run.turn("Say hello one last time.");
    console.log(`  after the slash command: ${settled.style ?? "no init seen"}`);
    check(
      settled.style === "probe-beta",
      "but the style in force does not move: the flag layer outranks what it writes",
    );

    // Nothing else here leaves anything on disk, and this has to be taken away
    // again: `probeResolvedDefaults` below reads this same directory, and a
    // local file outranks the project one it is about to write.
    const localSettings = path.join(scratch, ".claude", "settings.local.json");
    const persisted = existsSync(localSettings) ? readFileSync(localSettings, "utf8").trim() : null;
    console.log(`  and wrote down: ${(persisted ?? "nothing").replace(/\s+/g, " ")}`);
    check(
      persisted !== null && persisted.includes("probe-alpha"),
      "and it persists the pick to .claude/settings.local.json, where the next session would read it",
    );
    if (persisted !== null) rmSync(localSettings, { force: true });
  } finally {
    run.close();
  }
}

// ------------------------------------------------------------------ effort

/** The CLI hands the resolved level to Bash; nothing else says what a turn ran at. */
const ASK_EFFORT =
  "Run exactly this shell command with the Bash tool and then stop: " +
  'echo "effort=$CLAUDE_EFFORT" — do not run anything else and do not explain.';

function effortIn(text: string): string | null {
  return /effort=(\w+)/.exec(text)?.[1] ?? null;
}

async function probeEffort(): Promise<void> {
  console.log("\neffort");

  const run = open({ settings: { effortLevel: "high" } });
  try {
    const first = await run.turn(ASK_EFFORT);
    const started = effortIn(first.ran);
    console.log(`  started at: ${started ?? "nothing in CLAUDE_EFFORT"}`);
    check(
      started === "high",
      "an effort named in `settings` is the level the turn actually runs at",
    );

    let moveError: string | null = null;
    try {
      await run.session.applyFlagSettings({ effortLevel: "low" });
    } catch (error: any) {
      moveError = error?.message ?? String(error);
    }
    if (moveError) console.log(`  applyFlagSettings threw: ${moveError}`);
    check(moveError === null, "applyFlagSettings takes an effort change mid-session");

    const second = await run.turn(ASK_EFFORT);
    const moved = effortIn(second.ran);
    console.log(`  moved to: ${moved ?? "nothing in CLAUDE_EFFORT"}`);
    check(moved === "low", "the next turn runs at the new effort");

    // Session-scoped and never persisted, which is the whole reason the dial can
    // offer it without writing anything down.
    let maxError: string | null = null;
    try {
      await run.session.applyFlagSettings({ effortLevel: "max" });
    } catch (error: any) {
      maxError = error?.message ?? String(error);
    }
    if (maxError) console.log(`  max refused: ${maxError}`);
    const third = maxError ? null : await run.turn(ASK_EFFORT);
    const raised = third ? effortIn(third.ran) : null;
    console.log(`  raised to: ${raised ?? "not reached"}`);
    check(
      raised === "max",
      "`max` is accepted here though the persisted setting excludes it",
    );
  } finally {
    run.close();
  }
}

/**
 * Whether the composer can offer `max` too, or only the dial can.
 *
 * The persisted setting's own type excludes it — `Settings.effortLevel` stops at
 * `xhigh`, and the SDK says `max` is session-scoped and never written down. What
 * that leaves open is the layer in between: `settings` at launch is the flag
 * layer rather than a file, so it may take a level the file could not hold.
 *
 * It does not: the flag layer drops `max` and the session starts wherever the
 * layers below it say, as if nothing had been asked. The scratch project names
 * `low` for this one launch, so the answer can't depend on the user's own
 * `~/.claude/settings.json` — which is what this measured until CLI v2.1.283,
 * reading whatever level that file named and calling it a clamp.
 * `EffortLevel.launchable` sends `xhigh` in its place so a resume starts
 * somewhere definite rather than at Default.
 */
async function probeMaxAtLaunch(): Promise<void> {
  console.log("\nmax at launch");

  const projectSettings = path.join(scratch, ".claude", "settings.json");
  writeFileSync(projectSettings, JSON.stringify({ effortLevel: "low" }));
  const run = open({ settings: { effortLevel: "max" } });
  try {
    const first = await run.turn(ASK_EFFORT);
    const level = effortIn(first.ran);
    console.log(`  launched at: ${level ?? "nothing in CLAUDE_EFFORT"}`);
    check(
      level === "low",
      "`max` at launch is dropped for the project's own level, which is why only the dial offers it",
    );
  } finally {
    run.close();
    rmSync(projectSettings, { force: true });
  }
}

/**
 * Whether `xhigh` holds at launch, or is dropped like `max`.
 *
 * If it were, the composer's top row would be sending a level nothing runs at
 * and nothing would say so. One session, one turn, and it is what decides
 * whether `xhigh` stays in `EffortLevel.launchNames`.
 */
async function probeXhighAtLaunch(): Promise<void> {
  console.log("\nxhigh at launch");

  const run = open({ settings: { effortLevel: "xhigh" } });
  try {
    const first = await run.turn(ASK_EFFORT);
    const level = effortIn(first.ran);
    console.log(`  launched at: ${level ?? "nothing in CLAUDE_EFFORT"}`);
    check(
      level === "xhigh",
      "`xhigh` at launch is the level the turn runs at, so the composer's top row is real",
    );
  } finally {
    run.close();
  }
}

// ---------------------------------------------------------- what Default is

/**
 * What both pickers' Default row actually resolves to.
 *
 * The model picker has always named the model behind its Default, and these two
 * had nothing behind theirs — a row reading "Default" and nothing else, which is
 * the app declining to say what it is about to do. `resolveSettings` is the way
 * to say it: the CLI's own merge engine over the same cascade a `query()` would
 * see, run in-process without spawning anything.
 *
 * Three things are worth pinning and none of them is promised — the function is
 * marked `@alpha`:
 *
 *   in-process   it answers without a session, which is the whole point. The
 *                pickers are open before anything has been started, and the
 *                style list already costs a session to learn
 *   the cascade  the answer is the merge, not the contents of one file. Reading
 *                `~/.claude/settings.json` by hand would miss a project's own
 *                and get the precedence wrong
 *   the flag     what the app itself sends rides in the flag layer, above all
 *                of these. So this answers what Default *means* rather than
 *                what the last session ran at, which is the reading the row
 *                wants
 */
async function probeResolvedDefaults(): Promise<void> {
  console.log("\nwhat Default resolves to");

  check(typeof resolveSettings === "function", "the SDK exposes a settings resolver at all");
  if (typeof resolveSettings !== "function") return;

  const began = Date.now();
  const resolved: any = await resolveSettings({ cwd: scratch });
  const took = Date.now() - began;
  console.log(`  took ${took}ms, sources: ${resolved?.sources?.map((s: any) => s.source).join(", ") || "none"}`);
  console.log(`  outputStyle: ${JSON.stringify(resolved?.effective?.outputStyle)}`);
  console.log(`  effortLevel: ${JSON.stringify(resolved?.effective?.effortLevel)}`);

  check(
    resolved?.effective !== undefined,
    "it answers with the merged settings rather than a pile of sources",
  );
  // Cheap enough to ask on every folder change, which is what the composer does.
  check(took < 2_000, `it answers without spawning a CLI (${took}ms)`);

  // Both keys are the ones the pickers read. A rename on either is a Default
  // row that goes quiet — the app would show the bare word again and nothing
  // would say why.
  check(
    "outputStyle" in (resolved?.effective ?? {}) ||
      resolved?.provenance?.outputStyle === undefined,
    "outputStyle is the key it reports a style under",
  );
  check(
    "effortLevel" in (resolved?.effective ?? {}) ||
      resolved?.provenance?.effortLevel === undefined,
    "effortLevel is the key it reports an effort under",
  );

  // The scratch project has settings of its own, so the merge has something to
  // do beyond echoing the user's file back.
  writeFileSync(
    path.join(scratch, ".claude", "settings.json"),
    JSON.stringify({ outputStyle: "probe-beta", effortLevel: "low" }),
  );
  const merged: any = await resolveSettings({ cwd: scratch });
  console.log(`  with a project file: ${JSON.stringify(merged?.effective?.outputStyle)} / ${JSON.stringify(merged?.effective?.effortLevel)}`);
  check(
    merged?.effective?.outputStyle === "probe-beta" &&
      merged?.effective?.effortLevel === "low",
    "a project's own settings win over the config directory's, as the CLI merges them",
  );
  check(
    merged?.provenance?.outputStyle?.source === "project",
    `and it says which file the answer came from (${merged?.provenance?.outputStyle?.source})`,
  );

  // A settings file may hold `max`, and the resolver passes over it to the file
  // below, as the launch does one layer up. Were it to start answering, a
  // picker reading "Default · Max" would name a level nothing starts at.
  // Compared with no project file at all, so the user's own level can be
  // anything.
  writeFileSync(
    path.join(scratch, ".claude", "settings.json"),
    JSON.stringify({ effortLevel: "max" }),
  );
  const passed: any = await resolveSettings({ cwd: scratch });
  console.log(`  a file asking for max: ${JSON.stringify(passed?.effective?.effortLevel)}`);
  check(
    passed?.effective?.effortLevel === resolved?.effective?.effortLevel &&
      passed?.provenance?.effortLevel?.source !== "project",
    "`max` in a settings file is passed over for the file below it",
  );
}

/** An unfinished turn fails the part it was in, and the parts after it still run. */
async function part(probe: () => Promise<void>): Promise<void> {
  try {
    await probe();
  } catch (error) {
    if (!(error instanceof Unfinished)) throw error;
    check(false, `${probe.name} measured nothing: ${error.message}`);
  }
}

try {
  await part(probeStyle);
  await part(probeEffort);
  await part(probeMaxAtLaunch);
  await part(probeXhighAtLaunch);
  await part(probeResolvedDefaults);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(
  failures.length
    ? `\noutput-style: ${failures.length} check(s) failed`
    : "\noutput-style: all checks passed",
);
process.exit(failures.length ? 1 : 0);
