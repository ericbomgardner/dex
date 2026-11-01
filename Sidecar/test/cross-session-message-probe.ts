/**
 * Two SDK sessions messaging each other, and who actually hears.
 *
 *   node test/cross-session-message-probe.ts
 *
 * Every live CLI session writes itself into `~/.claude/sessions/<pid>.json` —
 * session id, cwd, a name, and the unix socket peers reach it on. That registry
 * is how `ListAgents` finds a peer and how `SendMessage` addresses one, and it
 * is the only thing that says a session is addressable at all. Nothing here had
 * ever checked that a session started through `query()` joins it: every record
 * on this machine could have come from a terminal and the join would have looked
 * identical. So the first reading is the plainest one — an SDK session appears
 * in the registry under the session id its own `system/init` announced, with a
 * name, and `CLAUDE_CODE_SESSION_NAME` on the subprocess sets that name.
 *
 * **The reading that matters is that `SendMessage` succeeding does not mean the
 * message was delivered.** A send to a peer that never sees it is answered
 * `{"success":true, …, "msg_id":…}`, indistinguishable from one that lands. What
 * decides it is **mode parity**, the CLI's policy when nothing is set: a message
 * auto-delivers only when the sending session's permission-mode class matches
 * the receiver's — bypass↔bypass or prompting↔prompting — and a mismatched
 * sender's is held for approval. There is no approval surface in an SDK session,
 * so held means gone: the CLI's own log says `headless: held peer message
 * expired (no approval surface) — dropped with an expired receipt`, and nothing
 * is written to the receiver's transcript to say a message was missed. A fleet UI
 * built on `SendMessage`'s answer would report every one of those as fine.
 *
 * Two ways through it, and both are pinned here because they are the two things
 * the app could ship. **Parity is the free one** — the app already starts every
 * session in `auto`, so its sessions reach each other with nothing set at all.
 * **`settings.crossSessionInbound: "accept"`** is the one that survives a peer in
 * some other mode: it goes in through the flag layer, an object on `query()`
 * exactly as the host passes `effortLevel`, and an explicit value always beats
 * parity. The mismatched case is kept as a control, since a run where everything
 * lands would say nothing about which of the two was doing the work.
 *
 * For a receiver that does accept, the shape depends on what it was doing, and
 * the two shapes are not alike:
 *
 *  - **Idle**, between turns with its input stream open, it takes the message as
 *    **its own user turn** — `isMeta: true`, content a plain string carrying the
 *    CLI's preamble around a `<cross-session-message …>` wrapper — and answers
 *    unprompted, with nobody at the keyboard.
 *  - **Busy** in a foreground tool call, the message is absorbed into the
 *    running turn: an `enqueue`, then an `attachment` of type `queued_command`
 *    with `commandMode: "prompt"`, then `queue-operation/remove` with
 *    `reason: "absorbed_mid_turn"` — and **no user turn is written at all.**
 *    The same shape a typed message takes mid-call, so a reader that only
 *    handles user turns shows a conversation the model has read and the pane
 *    has not.
 *  - **Parked on an `AskUserQuestion`**, it is enqueued the instant it arrives
 *    but not shown to the model, which has no next tool round until somebody
 *    answers. Answering releases it, into the absorbed shape above.
 *
 * Both shapes carry the same structured `origin` — `{kind: "peer", from,
 * verifiedPeerPid, msg_id, name, fromMode, body}` — with `body` the raw message.
 * That, not the prose wrapper, is what a reader should key on.
 *
 * Three things the probe has to keep honest about itself. The busy receiver must
 * really be busy: the CLI blocks a standalone `sleep`, and the first draft of
 * this measured a receiver that was already idle and read as a clean pass — so
 * the command is a `ping`, found by its own command text rather than as whatever
 * Bash ran first, and the run prints how far inside that call the send landed and
 * fails loudly if the command errored or if the send landed after it returned.
 * The parked receiver runs `bypassPermissions` like the others, or the gate above
 * would eat the message and the ask would get the credit; the SDK prints a
 * warning that `canUseTool` is shadowed in that mode and it is wrong about
 * `AskUserQuestion`, which still routes through it —
 * **don't "fix" that warning by changing the mode.** And the send is checked
 * through the tool call's own result rather than by grepping for the marker,
 * since the model often passes a `summary` and the CLI echoes that instead of
 * the message.
 *
 * Names are unique per run, so a probe overlapping with real sessions still
 * addresses its own receivers. Every session gets its own scratch cwd and is
 * closed in a `finally`; pids come off the registry records, so the leak check
 * names exact processes instead of guessing from `ps`.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

/** Long enough that the sender can start, list peers and send inside it. */
const BUSY_PINGS = 45;
/** How long the parked receiver is watched for a message it must not be shown. */
const PARKED_QUIET_MS = 10_000;
/** How long a message the gate ate is waited for before it is called gone. */
const GATED_WATCH_MS = 30_000;
/** Reading 4 is a report; this is how long it will wait for nothing. */
const IDLE_WATCH_MS = 30_000;
/** Nothing here may outlive this, so a sweep can't hang on it. */
const OVERALL_MS = 900_000;

const tag = randomBytes(3).toString("hex");
const RX_NAME = `probe-rx-${tag}`;
const RX2_NAME = `probe-rx2-${tag}`;
const RX3_NAME = `probe-rx3-${tag}`;
const RX4_NAME = `probe-rx4-${tag}`;
const NOWHERE = `zzznobody-${tag}`;
const MARKER_BUSY = `BUSYMARK-${randomBytes(4).toString("hex")}`;
const MARKER_PARKED = `PARKMARK-${randomBytes(4).toString("hex")}`;
const MARKER_GATED = `GATEMARK-${randomBytes(4).toString("hex")}`;
const MARKER_PARITY = `PARIMARK-${randomBytes(4).toString("hex")}`;
const MARKER_OPTED = `OPTMARK-${randomBytes(4).toString("hex")}`;
const MARKER_FORCED = `FORCEMARK-${randomBytes(4).toString("hex")}`;
const MARKER_IDLE = `IDLEMARK-${randomBytes(4).toString("hex")}`;

/** The mode the app starts its own sessions in, and so the one worth pinning. */
const APP_MODE = "auto";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Polls until `read` answers with something truthy, or gives up loudly. */
async function until<T>(
  what: string,
  ms: number,
  read: () => T | null | undefined | false,
): Promise<T> {
  const deadline = Date.now() + ms;
  for (;;) {
    const seen = read();
    if (seen) return seen as T;
    if (Date.now() > deadline) throw new Error(`gave up after ${ms}ms waiting for ${what}`);
    await sleep(250);
  }
}

/** The same poll, for something that is allowed not to happen. */
async function maybe<T>(ms: number, read: () => T | null | undefined | false): Promise<T | null> {
  const deadline = Date.now() + ms;
  for (;;) {
    const seen = read();
    if (seen) return seen as T;
    if (Date.now() > deadline) return null;
    await sleep(250);
  }
}

interface PeerOptions {
  cwd: string;
  name?: string;
  mode?: string;
  /** The flag layer, passed as an object exactly as the host passes it. */
  settings?: Record<string, unknown>;
  canUseTool?: (tool: string, input: any) => Promise<any>;
}

/**
 * A session with its input stream held open, so it can be handed more than one
 * turn — which is what lets one sender address three receivers in sequence, and
 * what leaves a receiver idle but alive for the readings that need one.
 */
class Peer {
  readonly label: string;
  readonly messages: any[] = [];
  readonly arrivedAt: number[] = [];
  sessionId: string | null = null;

  #pending: string[] = [];
  #wake: (() => void) | null = null;
  #done = false;
  #query: any;
  #drain: Promise<void>;

  constructor(label: string, options: PeerOptions) {
    this.label = label;

    const self = this;
    async function* input(): AsyncGenerator<unknown> {
      for (;;) {
        while (self.#pending.length) {
          const text = self.#pending.shift()!;
          yield { type: "user", message: { role: "user", content: text }, parent_tool_use_id: null };
        }
        if (self.#done) return;
        await new Promise<void>((resolve) => {
          self.#wake = resolve;
        });
      }
    }

    this.#query = query({
      prompt: input() as any,
      options: {
        cwd: options.cwd,
        model: "sonnet",
        systemPrompt: { type: "preset", preset: "claude_code" },
        permissionMode: options.mode ?? "bypassPermissions",
        ...(options.settings ? { settings: options.settings } : {}),
        ...(options.canUseTool ? { canUseTool: options.canUseTool } : {}),
        // The SDK replaces the subprocess environment rather than adding to it,
        // so a bare { CLAUDE_CODE_SESSION_NAME } starts a CLI with no PATH and
        // no credentials.
        ...(options.name
          ? {
              env: {
                ...(process.env as Record<string, string>),
                CLAUDE_CODE_SESSION_NAME: options.name,
              },
            }
          : {}),
      } as any,
    });

    this.#drain = (async () => {
      for await (const message of this.#query as AsyncIterable<any>) {
        this.messages.push(message);
        this.arrivedAt.push(Date.now());
        if (message.type === "system" && message.subtype === "init") {
          this.sessionId ??= message.session_id;
        }
      }
    })().catch((error) => {
      console.log(`  ${this.label}: stream ended — ${(error as Error).message}`);
    });
  }

  send(text: string): void {
    this.#pending.push(text);
    this.#wake?.();
    this.#wake = null;
  }

  get turnsFinished(): number {
    return this.messages.filter((m) => m.type === "result").length;
  }

  /** Hands over a turn and waits for the result that ends it. */
  async turn(text: string, ms: number): Promise<void> {
    const before = this.turnsFinished;
    this.send(text);
    await until(`${this.label} to finish a turn`, ms, () => this.turnsFinished > before);
  }

  said(): string {
    let text = "";
    for (const message of this.messages) {
      if (message.type !== "assistant") continue;
      for (const block of message.message?.content ?? []) {
        if (block.type === "text") text += `${block.text}\n`;
      }
    }
    return text;
  }

  calls(name: string): any[] {
    return this.messages
      .filter((m) => m.type === "assistant")
      .flatMap((m) => m.message?.content ?? [])
      .filter((b: any) => b.type === "tool_use" && b.name === name);
  }

  /** A tool result, with the CLI's own quoting intact so JSON reads as JSON. */
  resultFor(callId: string): { text: string; at: number; isError: boolean } | null {
    for (let i = 0; i < this.messages.length; i += 1) {
      const message = this.messages[i];
      if (message.type !== "user") continue;
      for (const block of message.message?.content ?? []) {
        if (block.type !== "tool_result" || block.tool_use_id !== callId) continue;
        const content = block.content;
        return {
          text:
            typeof content === "string"
              ? content
              : (content ?? []).map((b: any) => b.text ?? JSON.stringify(b)).join(""),
          at: this.arrivedAt[i],
          isError: block.is_error === true,
        };
      }
    }
    return null;
  }

  /**
   * What `SendMessage` answered for a given addressee. Found through the call
   * rather than by looking for the marker: the model usually passes a `summary`
   * and the CLI echoes that in place of the message body.
   */
  sendTo(address: string): { text: string; at: number; isError: boolean } | null {
    const call = this.calls("SendMessage").find((c: any) => c.input?.to === address);
    return call ? this.resultFor(call.id) : null;
  }

  /**
   * A call of `name` whose input matches, and when it arrived. Matched on the
   * input rather than taken as `calls(name)[0]`: a stray quick command first
   * would otherwise stand in for the long one, and the send would be bounded
   * against a call that had already returned.
   */
  callWith(name: string, matches: (input: any) => boolean): { id: string; at: number } | null {
    for (let i = 0; i < this.messages.length; i += 1) {
      const message = this.messages[i];
      if (message.type !== "assistant") continue;
      for (const block of message.message?.content ?? []) {
        if (block.type !== "tool_use" || block.name !== name) continue;
        if (matches(block.input ?? {})) return { id: block.id, at: this.arrivedAt[i] };
      }
    }
    return null;
  }

  /** Anywhere on the stream — what a negative reading has to be sure about. */
  mentions(marker: string): boolean {
    return this.messages.some((m) => JSON.stringify(m).includes(marker));
  }

  async close(): Promise<void> {
    this.#done = true;
    this.#wake?.();
    this.#wake = null;
    try {
      this.#query.close?.();
    } catch {
      /* already gone */
    }
    await Promise.race([this.#drain, sleep(5_000)]);
  }
}

function registryRecord(sessionId: string): any | null {
  const dir = path.join(homedir(), ".claude", "sessions");
  if (!existsSync(dir)) return null;
  for (const entry of readdirSync(dir)) {
    if (!entry.endsWith(".json")) continue;
    try {
      const record = JSON.parse(readFileSync(path.join(dir, entry), "utf8"));
      if (record?.sessionId === sessionId) return record;
    } catch {
      /* half-written, or not ours */
    }
  }
  return null;
}

function transcriptFor(sessionId: string | null): string | null {
  if (!sessionId) return null;
  const projects = path.join(homedir(), ".claude", "projects");
  if (!existsSync(projects)) return null;
  for (const slug of readdirSync(projects)) {
    const candidate = path.join(projects, slug, `${sessionId}.jsonl`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function records(sessionId: string | null): any[] {
  const file = transcriptFor(sessionId);
  if (!file || !existsSync(file)) return [];
  return readFileSync(file, "utf8")
    .split("\n")
    .filter(Boolean)
    .flatMap((line) => {
      try {
        return [JSON.parse(line)];
      } catch {
        return [];
      }
    });
}

/** Every transcript record naming the marker, in the order they were written. */
function naming(sessionId: string | null, marker: string): any[] {
  return records(sessionId).filter((r) => JSON.stringify(r).includes(marker));
}

/** The queue record the CLI writes the moment a peer message arrives. */
function enqueued(sessionId: string | null, marker: string): any | null {
  return (
    naming(sessionId, marker).find((r) => r.type === "queue-operation" && r.operation === "enqueue") ??
    null
  );
}

/**
 * The record that puts a peer message in front of the model — a user turn when
 * it was idle, an absorbed attachment when it was busy. Both carry `origin`.
 */
function shown(sessionId: string | null, marker: string): any | null {
  return (
    naming(sessionId, marker).find((r) => r.type === "user" || r.type === "attachment") ?? null
  );
}

function originOf(record: any): any {
  return record?.origin ?? record?.attachment?.origin ?? null;
}

function alive(pid: number): boolean {
  try {
    execFileSync("ps", ["-p", String(pid)], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

const failures: string[] = [];
function check(held: unknown, description: string): void {
  console.log(`${held ? "  ok" : "FAIL"}  ${description}`);
  if (!held) failures.push(description);
}

/** What a transcript reader has to recognise. Printed, never asserted on. */
function describeDelivery(sessionId: string | null, marker: string): void {
  const named = naming(sessionId, marker);
  if (!named.length) {
    console.log("  shape: no transcript record names it");
    return;
  }
  console.log(
    `  shape: ${named.length} record(s) — ${named
      .map((r) => `${r.type}${r.operation ? `/${r.operation}` : ""}${r.attachment ? `(${r.attachment.type})` : ""}`)
      .join(", ")}`,
  );

  const queue = named.find((r) => r.type === "queue-operation");
  if (queue) console.log(`  shape: enqueued as ${JSON.stringify(String(queue.content).slice(0, 120))}`);
  const removal = named.find((r) => r.type === "queue-operation" && r.operation === "remove");
  if (removal) console.log(`  shape: removed from the queue with reason=${removal.reason}`);

  const front = shown(sessionId, marker);
  if (!front) {
    console.log("  shape: nothing put it in front of the model");
    return;
  }
  const body = front.type === "attachment" ? front.attachment : front;
  console.log(
    `  shape: shown as type=${front.type}` +
      (front.type === "attachment" ? `/${body.type} commandMode=${body.commandMode}` : ` role=${front.message?.role}`),
  );
  console.log(`  shape: isMeta=${body.isMeta ?? front.isMeta ?? "absent"} promptSource=${front.promptSource ?? "absent"}`);
  const text = front.type === "attachment" ? body.prompt : front.message?.content;
  const attributes = /<cross-session-message([^>]*)>/.exec(String(text));
  console.log(`  shape: wrapper ${attributes ? JSON.stringify(attributes[1].trim()) : "not in the text"}`);
  console.log(`  shape: origin ${JSON.stringify(originOf(front))}`);
  console.log(
    `  shape: content is ${typeof text === "string" ? "a string" : "blocks"}, opening ${JSON.stringify(String(text).slice(0, 80))}`,
  );
}

const scratchRoot = mkdtempSync(path.join(tmpdir(), "dex-cross-session-"));
function scratch(name: string): string {
  const dir = path.join(scratchRoot, name);
  mkdirSync(dir, { recursive: true });
  return dir;
}

const started = Date.now();
const watchdog = setTimeout(() => {
  console.error(`\ncross-session: nothing finished within ${OVERALL_MS}ms — giving up`);
  process.exit(1);
}, OVERALL_MS);
watchdog.unref?.();

const peers: Peer[] = [];
const pids: number[] = [];

/** Remembers the pid so the leak check at the end can name it. */
async function join(peer: Peer, what: string): Promise<any> {
  const id = await until(`${peer.label} to announce its session id`, 120_000, () => peer.sessionId);
  const record = await until(what, 60_000, () => registryRecord(id));
  if (typeof record.pid === "number") pids.push(record.pid);
  return record;
}

try {
  // ---- 1. the registry join ------------------------------------------------
  console.log("\n--- registry join ---");
  const receiver = new Peer("receiver", { cwd: scratch("receiver"), name: RX_NAME });
  peers.push(receiver);

  receiver.send(
    "Run exactly this with the Bash tool, passing a timeout of 120000: " +
      `ping -c ${BUSY_PINGS} -i 1 127.0.0.1 > /dev/null — it takes about ${BUSY_PINGS} seconds and ` +
      "that is the point. Run nothing else and do not background it. When it returns, tell me, word " +
      "for word, the text of any message another Claude session sent you while it was running. If " +
      "there was none, say NOTHING RECEIVED.",
  );

  const record = await join(receiver, "the receiver to join the session registry");
  const receiverId = receiver.sessionId;
  console.log(`  registry: ${record.pid}.json  entrypoint=${record.entrypoint} kind=${record.kind}`);
  console.log(`  registry: name=${record.name} nameSource=${record.nameSource ?? "absent"}`);
  console.log(`  registry: socket=${record.messagingSocketPath}`);

  check(record.sessionId === receiverId, "an SDK session joins the registry under its own session id");
  check(typeof record.name === "string" && record.name.length > 0, "the registry record carries a name");
  check(record.name === RX_NAME, "CLAUDE_CODE_SESSION_NAME is the name a peer addresses it by");
  // Reported, not asserted: the field is simply absent on a record written at
  // registration, so a session named through the environment looks here exactly
  // like one that derived its name. The name itself is the reading.
  console.log(`  nameSource on the fresh record: ${record.nameSource ?? "absent"}`);
  const rxAddress: string = record.name;

  // ---- 2. a busy receiver, and 5. a name nobody answers to -----------------
  console.log("\n--- delivery to a busy receiver ---");
  const pingCall = await until(
    "the receiver to be inside its long ping command",
    180_000,
    () =>
      receiver.callWith("Bash", (input) => {
        const command = String(input.command ?? "");
        return command.includes("ping") && command.includes(`-c ${BUSY_PINGS}`);
      }),
  );
  console.log(`  the receiver is mid-turn in a ${BUSY_PINGS}s foreground command`);

  const sender = new Peer("sender", { cwd: scratch("sender") });
  peers.push(sender);

  await sender.turn(
    "Use ListAgents once to see the other Claude sessions running on this machine. Then use " +
      `SendMessage with to: "${rxAddress}" and message: "${MARKER_BUSY}". Then use SendMessage again ` +
      `with to: "${NOWHERE}" and message: "ping" — that name is expected to fail, so do not retry it ` +
      "and do not look for a different one. Then report, verbatim, what each SendMessage told you.",
    300_000,
  );
  await join(sender, "the sender to join the session registry");

  const busySend = sender.sendTo(rxAddress);
  const nowhereSend = sender.sendTo(NOWHERE);
  console.log(`  to a live peer: ${busySend?.text.slice(0, 160) ?? "no such call"}`);
  console.log(`  to nobody:      ${nowhereSend?.text.slice(0, 160) ?? "no such call"}`);

  check(sender.calls("ListAgents").length > 0, "ListAgents is offered to a session started through the SDK");
  check(busySend !== null, "so is SendMessage, and it was called with the peer's name");
  check(busySend?.text.includes(`"success":true`) === true, "SendMessage to a live peer answers success: true");
  check(busySend?.text.includes("msg_id") === true, "and carries a msg_id for the message it accepted");
  check(
    nowhereSend?.text.includes("No agent named") === true && nowhereSend?.text.includes(NOWHERE) === true,
    "SendMessage to a name nobody answers to fails in the result rather than throwing",
  );
  check(nowhereSend?.text.includes(`"success":false`) === true, "and reports that as success: false");

  const busyCall = await until(
    "the receiver's long command to return",
    300_000,
    () => receiver.resultFor(pingCall.id),
  );
  const seconds = (ms: number) => `${(ms / 1000).toFixed(1)}s`;
  console.log(
    busySend
      ? `  sent ${seconds(busySend.at - pingCall.at)} after the Bash tool_use arrived, ` +
          `${seconds(busyCall.at - busySend.at)} before its result`
      : "  sent: no SendMessage call to measure",
  );
  // The reason the first draft measured nothing: the CLI blocks a standalone
  // `sleep`, the call came back instantly, and a receiver that was already idle
  // read as a pass. Both halves are gated now.
  check(!busyCall.isError, "the long command actually ran, so the receiver really was busy");
  check(
    (busySend?.at ?? Infinity) < busyCall.at,
    "the message was sent before that command returned — otherwise this measures an idle receiver",
  );

  await until("the busy receiver to finish its turn", 300_000, () => receiver.turnsFinished > 0);
  await maybe(60_000, () => shown(receiverId, MARKER_BUSY));

  const busyQueued = enqueued(receiverId, MARKER_BUSY);
  const busyShown = shown(receiverId, MARKER_BUSY);
  check(busyQueued !== null, "a message to a receiver inside a long tool call is queued as it arrives");
  check(busyShown !== null, "and it is put in front of the model once the call returns");
  check(
    busyShown?.type === "attachment" && busyShown.attachment?.type === "queued_command",
    "it is absorbed into the running turn as a queued_command attachment, not written as a user turn",
  );
  check(
    originOf(busyShown)?.kind === "peer" && originOf(busyShown)?.body === MARKER_BUSY,
    "the record carries a structured peer origin whose body is the message itself",
  );
  // The model repeating it back is compliance, not delivery, so it is printed.
  console.log(`  the receiver read it back: ${receiver.said().includes(MARKER_BUSY) ? "yes" : "no"}`);
  describeDelivery(receiverId, MARKER_BUSY);

  // ---- 3. a parked receiver ----------------------------------------------
  console.log("\n--- delivery to a receiver parked on a question ---");
  let unpark: (() => void) | null = null;
  let askedAt = 0;
  const answered = new Promise<void>((resolve) => {
    unpark = resolve;
  });

  const questioner = new Peer("parked receiver", {
    cwd: scratch("parked"),
    name: RX2_NAME,
    // Same mode as every other session here on purpose: in any other mode the
    // inbound gate below would eat the message and the ask would get the credit.
    // The SDK warns that canUseTool is shadowed by bypassPermissions; it is
    // wrong about AskUserQuestion, which still routes through it.
    canUseTool: async (toolName: string, input: any) => {
      if (toolName !== "AskUserQuestion") {
        return { behavior: "deny", message: "only the question is under test" };
      }
      askedAt = Date.now();
      const question = input.questions[0].question;
      await answered;
      return {
        behavior: "allow",
        updatedInput: { questions: input.questions, answers: { [question]: "red" } },
      };
    },
  });
  peers.push(questioner);

  questioner.send(
    "Use the AskUserQuestion tool right now to ask me one question: should the badge be red or blue. " +
      "Ask it before doing anything else. After I answer, tell me, word for word, the text of any " +
      "message another Claude session sent you, or say NOTHING RECEIVED.",
  );

  const parkedRecord = await join(questioner, "the parked receiver to join the registry");
  const questionerId = questioner.sessionId;
  const parkedAddress: string = parkedRecord.name;

  await until("the parked receiver to sit on its question", 180_000, () => askedAt > 0);
  console.log(`  ${parkedAddress} is parked on an unanswered AskUserQuestion`);

  await sender.turn(
    `Use SendMessage with to: "${parkedAddress}" and message: "${MARKER_PARKED}". Do nothing else, ` +
      "then report what it told you.",
    300_000,
  );
  check(
    sender.sendTo(parkedAddress)?.text.includes(`"success":true`) === true,
    "SendMessage to a parked peer is accepted exactly as a delivered one is",
  );

  await sleep(PARKED_QUIET_MS);
  const parkedQueued = enqueued(questionerId, MARKER_PARKED);
  const parkedShownEarly = shown(questionerId, MARKER_PARKED);
  console.log(
    `  ${Math.round(PARKED_QUIET_MS / 1000)}s into the ask — queued: ${parkedQueued ? "yes" : "no"}; ` +
      `shown to the model: ${parkedShownEarly ? "yes" : "no"}`,
  );
  if (parkedShownEarly) {
    console.log(
      "\nREADING CHANGED: a session parked on an AskUserQuestion was handed a peer's message before\n" +
        "the ask was answered. A message is folded in at a tool round and a parked session has no next\n" +
        "one, so either the CLI now interrupts the ask or delivery no longer waits for a round. This is\n" +
        "not a scaffolding failure: a parked row can no longer be assumed quiet.",
    );
  }
  check(parkedQueued !== null, "a parked receiver still takes the message onto its queue as it arrives");
  check(parkedShownEarly === null, "but the model is not shown it while the ask is open");
  check(!questioner.mentions(MARKER_PARKED), "and nothing about it reaches the session's own stream");

  unpark!();
  const released = await maybe(240_000, () => shown(questionerId, MARKER_PARKED));
  check(released !== null, "answering the question releases the message to the model");
  console.log(
    `  once answered — shown as ${released ? `${released.type}/${released.attachment?.type ?? released.message?.role}` : "not at all"}`,
  );

  // ---- 6. a sender and a receiver whose modes don't match -----------------
  console.log(`\n--- delivery from a bypass sender to a receiver in ${APP_MODE} ---`);
  const gated = new Peer("gated receiver", { cwd: scratch("gated"), name: RX3_NAME, mode: APP_MODE });
  peers.push(gated);
  await gated.turn("Say READY and nothing else.", 180_000);
  const gatedRecord = await join(gated, "the gated receiver to join the registry");
  const gatedId = gated.sessionId;
  const gatedAddress: string = gatedRecord.name;
  console.log(`  ${gatedAddress} is idle, registered, and running in ${APP_MODE}`);

  await sender.turn(
    `Use SendMessage with to: "${gatedAddress}" and message: "${MARKER_GATED}". Do nothing else, ` +
      "then report what it told you.",
    300_000,
  );
  const gatedSend = sender.sendTo(gatedAddress);
  console.log(`  the sender was told: ${gatedSend?.text.slice(0, 160) ?? "no such call"}`);
  check(
    gatedSend?.text.includes(`"success":true`) === true,
    `SendMessage across a mode mismatch is answered success: true, like any other`,
  );

  const reached = await maybe(GATED_WATCH_MS, () => naming(gatedId, MARKER_GATED).length > 0);
  if (reached) {
    console.log(
      "\nREADING CHANGED: a mismatched sender's message was delivered. Mode parity has held these back\n" +
        "behind an approval a headless session cannot give, and the send was answered success and then\n" +
        "dropped. If the gate has moved, SendMessage's answer can mean delivery for the first time —\n" +
        "re-read it deliberately before relying on it.",
    );
  }
  check(
    !reached,
    "a mismatched sender's message is never handed to the receiver — success is not delivery",
  );
  check(
    enqueued(gatedId, MARKER_GATED) === null,
    "and it is dropped ahead of the queue, so nothing in its transcript says a message was missed",
  );
  console.log(`  the gated receiver ran ${gated.turnsFinished - 1} turn(s) after the send`);

  // ---- 7 and 8. the two ways the app could make its own sessions hear ------
  console.log(`\n--- delivery between two sessions in ${APP_MODE} ---`);
  const opted = new Peer("opted-in receiver", {
    cwd: scratch("opted"),
    name: RX4_NAME,
    mode: APP_MODE,
    // The flag layer, an object as the host passes it for effortLevel. The
    // docs say an explicit value always wins over mode parity.
    settings: { crossSessionInbound: "accept" },
  });
  peers.push(opted);
  await opted.turn("Say READY and nothing else.", 180_000);
  const optedRecord = await join(opted, "the opted-in receiver to join the registry");
  const optedId = opted.sessionId;
  const optedAddress: string = optedRecord.name;

  const peerSender = new Peer("matched sender", { cwd: scratch("matched"), mode: APP_MODE });
  peers.push(peerSender);
  await peerSender.turn(
    `Use SendMessage with to: "${gatedAddress}" and message: "${MARKER_PARITY}". Then use SendMessage ` +
      `with to: "${optedAddress}" and message: "${MARKER_OPTED}". Then report both results verbatim.`,
    300_000,
  );
  await join(peerSender, "the matched sender to join the registry");

  const paritySend = peerSender.sendTo(gatedAddress);
  const optedSend = peerSender.sendTo(optedAddress);
  console.log(`  ${APP_MODE} → ${APP_MODE}, nothing set: ${paritySend?.text.slice(0, 150) ?? "no such call"}`);
  console.log(`  ${APP_MODE} → crossSessionInbound accept: ${optedSend?.text.slice(0, 150) ?? "no such call"}`);

  const byParity = await maybe(GATED_WATCH_MS, () => shown(gatedId, MARKER_PARITY));
  const byOptIn = await maybe(GATED_WATCH_MS, () => shown(optedId, MARKER_OPTED));
  console.log(
    `  landed by mode parity: ${byParity ? `yes, as a ${byParity.type}` : "no"}; ` +
      `landed by opting in: ${byOptIn ? `yes, as a ${byOptIn.type}` : "no"}`,
  );

  // Both are pinned, because they are the two things the app could ship and it
  // needs to know which one it is relying on. Parity is the free one — the app
  // already starts every session in the same mode — and the opt-in is the one
  // that survives a session in some other mode.
  check(
    byParity !== null,
    `two sessions both in ${APP_MODE} reach each other with nothing set — mode parity is enough`,
  );
  check(
    byOptIn !== null,
    "and a receiver that set crossSessionInbound 'accept' takes a matched sender's message too",
  );
  if (byParity) describeDelivery(gatedId, MARKER_PARITY);

  // Sent from a matched sender, the opt-in above proves nothing: parity would
  // have delivered it anyway. This is the send that isolates the setting — the
  // same bypass sender whose message the un-set receiver never saw.
  await sender.turn(
    `Use SendMessage with to: "${optedAddress}" and message: "${MARKER_FORCED}". Do nothing else, ` +
      "then report what it told you.",
    300_000,
  );
  const forced = await maybe(GATED_WATCH_MS, () => shown(optedId, MARKER_FORCED));
  console.log(
    `  the same mismatched sender, into crossSessionInbound accept: ${forced ? `landed as a ${forced.type}` : "dropped"}` +
      `${forced ? ` (fromMode ${originOf(forced)?.fromMode})` : ""}`,
  );
  check(
    forced !== null,
    "crossSessionInbound 'accept' delivers across the mode mismatch that is otherwise dropped",
  );

  // ---- 4. an idle receiver (report only) ----------------------------------
  console.log("\n--- delivery to an idle receiver (report only) ---");
  const turnsBefore = receiver.turnsFinished;
  await sender.turn(
    `Use SendMessage with to: "${rxAddress}" and message: "${MARKER_IDLE}". Do nothing else, then ` +
      "report what it told you.",
    300_000,
  );
  const woke = await maybe(IDLE_WATCH_MS, () => shown(receiverId, MARKER_IDLE));
  await maybe(60_000, () => receiver.turnsFinished > turnsBefore);
  console.log(
    `  within ${IDLE_WATCH_MS / 1000}s — shown to the model: ${woke ? `yes, as a ${woke.type}` : "no"}; ` +
      `turns it ran unprompted: ${receiver.turnsFinished - turnsBefore}`,
  );
  if (woke) describeDelivery(receiverId, MARKER_IDLE);
  console.log(
    "  (report only: a receiver waking on its own means a row can move with nobody at the keyboard,\n" +
      "   and one that doesn't means a queued message waits for the next thing typed)",
  );
} finally {
  for (const peer of peers) await peer.close();
  await sleep(2_000);

  const leaked = pids.filter((pid) => alive(pid));
  console.log("\n--- cleanup ---");
  console.log(`  sessions started: ${pids.length}; still running: ${leaked.length}`);
  check(leaked.length === 0, "every CLI this probe started is gone once its input stream closes");
  if (leaked.length) console.log(`  leaked pids: ${leaked.join(", ")}`);

  rmSync(scratchRoot, { recursive: true, force: true });
  clearTimeout(watchdog);
}

console.log(`\ncross-session: ${Math.round((Date.now() - started) / 1000)}s`);
console.log(
  failures.length
    ? `cross-session: ${failures.length} check(s) failed`
    : "cross-session: all checks passed",
);
process.exit(failures.length ? 1 : 0);
