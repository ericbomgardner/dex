import { randomUUID, type UUID } from "node:crypto";
import {
  query,
  type CanUseTool,
  type EffortLevel,
  type Options,
  type PermissionMode,
  type PermissionResult,
  type PermissionUpdate,
  type Query,
  type SDKMessage,
  type SDKPartialAssistantMessage,
  type SDKUserMessage,
  type SettingSource,
  type Settings,
} from "@anthropic-ai/claude-agent-sdk";

import { FOLDERS_BRIEF, MEDIA_BRIEF, SCREEN_BRIEF } from "./briefs.ts";
import { DEX_SERVER, LIST_SESSIONS_TOOL, START_SESSION_TOOL, dexServer, type Launcher } from "./dex-server.ts";
import { stirred } from "./exit-policy.ts";
import { KeyFile, keylessEnvironment } from "./keyfile.ts";
import { log, why } from "./log.ts";
import { McpRetries, mcpReadings } from "./mcp.ts";
import { decisionFor, permissionOptions, sessionRules, takeoverOptions } from "./permissions.ts";
import { drivesScreen, screenDrive } from "./screen.ts";
import { PushStream } from "./stream.ts";
import { configDirectory } from "./support.ts";
import type {
  Answer,
  Ask,
  Event,
  RunningTask,
  SessionState,
  McpServerReading,
  SessionOrigin,
  SessionSummary,
} from "./protocol.ts";

const UNACCEPTED_LIMIT = 64;
const ASKING_TOOLS = new Set(["AskUserQuestion", "ExitPlanMode"]);

/** On the SDK's stream but not in its types: whether a send was taken into a turn. */
interface CommandLifecycle {
  type: "command_lifecycle";
  state?: string;
  command_uuid?: string;
}

/** `Query` methods the SDK has and doesn't declare; each names the probe that checks it is still there. */
interface UndeclaredQuery {
  /** `test/rename-probe.ts` */
  renameSession(title: string, sessionId: string | null): Promise<void>;
  /** `test/side-question-probe.ts` */
  askSideQuestion(
    question: string,
    options: { history: { question: string; response: string }[] },
  ): Promise<{ response?: string } | null | undefined>;
  /** `test/mcp-actions-probe.ts` */
  mcpAuthenticate(server: string): Promise<{ authUrl?: string; callbackExpected?: boolean } | null | undefined>;
}

/** The SDK's `Query`, every control method optional: each is checked for before it is called. */
export type SessionQuery = AsyncIterable<SDKMessage | CommandLifecycle> &
  Partial<Omit<Query, typeof Symbol.asyncIterator | "next" | "return" | "throw"> & UndeclaredQuery>;

interface ParkedAsk {
  ask: Ask;
  resolve: (decision: PermissionResult) => void;
  input: Record<string, unknown>;
  suggestions: PermissionUpdate[];
  grant: string | null;
  /** Takes the abort listener off the call's signal, which outlives the ask. */
  detach: () => void;
}

export interface SessionOptions {
  cwd: string;
  prompt: string;
  model?: string;
  permissionMode?: string;
  name?: string;
  origin?: SessionOrigin;
  settingSources?: SettingSource[];
  outputStyle?: string;
  effort?: string;
  resume?: string;
  key?: string;
  apiKey?: string;
  /** Stands in for the SDK's `query`, so a test can drive a session without a CLI. */
  query?: (args: { prompt: AsyncIterable<SDKUserMessage>; options: Options }) => SessionQuery;
}

export class HostedSession {
  readonly key: string;
  readonly cwd: string;
  readonly name: string | null;
  readonly origin: SessionOrigin | null;
  readonly startedAt = new Date().toISOString();

  sessionId: string | null = null;
  model: string | null = null;
  permissionMode: string;
  commands: string[] | null = null;
  mcpServers: McpServerReading[] | null = null;
  effort: string | null;
  outputStyle: string | null = null;
  state: SessionState = "starting";
  lastActivityAt = this.startedAt;
  /** From a send taken or an agent's report until the next result: the turn is coming, though nothing says `running` yet. */
  turnOwed = false;

  readonly #input = new PushStream();
  /** Sent and not yet taken into a turn, as far as `command_lifecycle` has said. */
  #unaccepted: UUID[] = [];
  /** Keeps cut-in sends in the order they were made across their awaits. */
  #cutIns: Promise<void> = Promise.resolve();
  /** A message went into a working turn and the turn hasn't taken it yet. */
  #messageWaiting = false;
  /**
   * The reply streaming now has started a call. A cut-in throws away every call
   * in a reply it cuts, written or half-written, so sends wait for its end
   * (measured: test/writing-call-probe.ts).
   */
  #replyHasCall = false;
  /** That reply is putting a question or a plan to the user, which a cut-in could take off them. */
  #replyAsks = false;
  #replyEnded: ((asked: boolean) => void)[] = [];
  /**
   * The main reply's calls with neither a result nor a task yet: in auto mode
   * the classifier is still deciding, and a cut-in there aborts the call
   * (measured: test/now-priority-probe.ts).
   */
  #callsStarting = new Set<string>();
  #callsStarted: (() => void)[] = [];
  readonly #options: SessionOptions;
  #keyFile: KeyFile | null = null;
  readonly #post: (event: Event) => void;
  readonly #parked = new Map<string, ParkedAsk>();
  /** MCP tools answered "Allow for this session"; gone with the host's session. */
  readonly #granted = new Set<string>();
  readonly #tasks = new Map<string, RunningTask>();
  readonly #toolNames = new Map<string, string>();
  #query: SessionQuery | null = null;
  #retired = false;
  #mcpRecheck: ReturnType<typeof setTimeout> | null = null;
  #mcpLogins = new Map<string, number>();
  readonly #mcpRetries = new McpRetries(
    async (server) => {
      await this.#query?.reconnectMcpServer?.(server);
    },
    () => this.#reportMcp(),
  );
  #namePersisted = false;
  readonly #launch: Launcher | null;

  constructor(options: SessionOptions, emit: (event: Event) => void, launch?: Launcher) {
    this.#options = options;
    this.#launch = launch ?? null;
    this.key = options.key ?? randomUUID();
    this.cwd = options.cwd;
    this.name = options.name ?? null;
    this.origin = options.origin ?? null;
    this.permissionMode = options.permissionMode ?? "default";
    this.effort = options.effort ?? null;
    this.#post = emit;
  }

  summary(): SessionSummary {
    return {
      key: this.key,
      sessionId: this.sessionId,
      cwd: this.cwd,
      name: this.name,
      origin: this.origin,
      state: this.state,
      model: this.model,
      permissionMode: this.permissionMode,
      effort: this.effort,
      outputStyle: this.outputStyle,
      startedAt: this.startedAt,
      lastActivityAt: this.lastActivityAt,
      commands: this.commands,
      mcpServers: this.mcpServers,
    };
  }

  parkedAsks(): Ask[] {
    return [...this.#parked.values()].map((parked) => parked.ask);
  }

  runningTasks(): RunningTask[] {
    return [...this.#tasks.values()];
  }

  /**
   * Whether this session can be let go without taking work with it.
   *
   * Idle is the turn being over, which is not the same as nothing running: a
   * background agent outlives the turn that launched it, so a session sits idle
   * with an agent still going, and with an ask of that agent's own parked.
   */
  reapable(now: number, after: number): boolean {
    if (this.state !== "idle") return false;
    if (this.#parked.size > 0 || this.#tasks.size > 0) return false;
    return now - Date.parse(this.lastActivityAt) >= after;
  }

  start(): void {
    this.#input.push(this.#options.prompt);
    this.#keyFile = this.#options.apiKey ? new KeyFile(this.#options.apiKey) : null;

    const settings: Settings = {
      ...(this.#options.outputStyle ? { outputStyle: this.#options.outputStyle } : {}),
      // Passed on unchecked: the CLI drops a `max` here, and output-style-probe.ts measures that.
      ...(this.#options.effort ? { effortLevel: this.#options.effort as Settings["effortLevel"] } : {}),
      ...(this.#keyFile ? { apiKeyHelper: this.#keyFile.helper } : {}),
    };

    const dex = this.#launch ? dexServer(this.key, this.#launch, () => this.sessionId) : null;

    try {
      let options: Options = {
        cwd: this.#options.cwd,
        // Omitted, `systemPrompt` is an empty custom prompt rather than the
        // CLI's own, so a hosted session would run without one at all.
        systemPrompt: {
          type: "preset",
          preset: "claude_code",
          append: [SCREEN_BRIEF, FOLDERS_BRIEF, MEDIA_BRIEF].join("\n\n"),
        },
        ...(this.#options.model ? { model: this.#options.model } : {}),
        ...(this.#keyFile ? { env: keylessEnvironment() } : {}),
        ...(dex
          ? { mcpServers: { [DEX_SERVER]: dex }, allowedTools: [START_SESSION_TOOL, LIST_SESSIONS_TOOL] }
          : {}),
        ...(this.#options.resume ? { resume: this.#options.resume } : {}),
        // A resumed process with no custom-title goes back to a made-up name in the CLI's registry, which is what ListAgents shows.
        ...(this.#options.resume && this.name && !this.name.startsWith("/") ? { title: this.name } : {}),
        ...(this.#options.permissionMode
          ? { permissionMode: this.#options.permissionMode as PermissionMode }
          : {}),
        ...(this.#options.settingSources
          ? { settingSources: this.#options.settingSources }
          : {}),
        // The flag layer: above the settings files, below managed policy, and
        // written to no file. It is the app's way in for the style — since CLI
        // v2.1.278 `applyFlagSettings` moves one on a running session too, but
        // the app binds the style at launch and offers no per-session dial — and
        // the only way to ask for an effort the settings files are not allowed
        // to hold. Being the flag layer is also why the style in force does not
        // follow `/output-style`: that writes `.claude/settings.local.json`, and
        // this outranks it on a session that was started with a style.
        ...(Object.keys(settings).length > 0 ? { settings } : {}),
        toolConfig: { askUserQuestion: { previewFormat: "html" } },
        includePartialMessages: true,
        // In auto mode a Bash call never reaches `canUseTool` on its own, so
        // a command that drives the screen looks like any other. A hook
        // answering `ask` sends that one call through the same door the
        // questions use (measured: test/screen-takeover-probe.ts).
        hooks: {
          PreToolUse: [
            {
              matcher: "Bash",
              hooks: [
                async (hookInput) =>
                  hookInput.hook_event_name === "PreToolUse" && drivesScreen(hookInput.tool_name, hookInput.tool_input)
                    ? {
                        hookSpecificOutput: {
                          hookEventName: "PreToolUse",
                          permissionDecision: "ask",
                          permissionDecisionReason: "drives the user's screen",
                        },
                      }
                    : {},
              ],
            },
          ],
        },
        canUseTool: (toolName, input, opts) => this.#park(toolName, input, opts),
      };
      this.#query = (this.#options.query ?? query)({ prompt: this.#input, options });
    } catch (error) {
      this.#keyFile?.remove();
      throw error;
    }

    void this.#drain(this.#query);
  }

  send(text: string): void {
    const uuid = randomUUID();
    this.turnOwed = true;
    this.#unaccepted.push(uuid);
    if (this.#unaccepted.length > UNACCEPTED_LIMIT) this.#unaccepted.shift();

    // Through the chain either way, or a plain send overtakes a cut-in still
    // waiting on `backgroundTasks()` and that cut-in then cuts its reply.
    // Not on `asking`: nothing done to tasks unparks an ask.
    if (this.state !== "running") {
      this.#queueSend(text, uuid, () => this.#input.push(text, uuid));
      return;
    }
    this.#messageWaiting = true;
    this.#queueSend(text, uuid, () => this.#cutIn(text, uuid));
  }

  /** A link that fails sends its message plain rather than taking every later one down with it. */
  #queueSend(text: string, uuid: UUID, step: () => void | Promise<void>): void {
    this.#cutIns = this.#cutIns.then(step).catch((error: unknown) => {
      log(`send to ${this.key} failed, sending it plain: ${why(error)}`);
      try {
        this.#input.push(text, uuid);
      } catch (again) {
        log(`plain send to ${this.key} failed too: ${why(again)}`);
      }
    });
  }

  /**
   * What the terminal's send-now does since CLI v2.1.281: move the running
   * tasks off the turn, then send with `priority: "now"`, which cuts a
   * streaming reply. Backgrounding first is what saves a foreground agent;
   * "now" on its own kills it (measured: test/now-priority-probe.ts).
   */
  async #cutIn(text: string, uuid: UUID): Promise<void> {
    if (await this.#replyWritten()) {
      this.#input.push(text, uuid);
      return;
    }
    // Before the hold too: a call queued behind a foreground Bash starts only
    // once the Bash is out of the way.
    await this.#background();
    if (await this.#callsSettled()) {
      this.#input.push(text, uuid);
      return;
    }
    await this.#background();
    const asked = await this.#callsSettled();
    this.#input.push(text, uuid, asked ? undefined : "now");
  }

  async #background(): Promise<void> {
    try {
      await this.backgroundTasks();
    } catch (error) {
      log(`backgroundTasks failed for ${this.key}: ${why(error)}`);
    }
  }

  /** Waits out a call being written and then one being started, saying whether the reply was asking. */
  async #callsSettled(): Promise<boolean> {
    while (true) {
      if (await this.#replyWritten()) return true;
      if (this.#callsStarting.size === 0) return false;
      await new Promise<void>((resolve) => this.#callsStarted.push(resolve));
    }
  }

  #callStarted(id: string | null | undefined): void {
    if (!id || !this.#callsStarting.delete(id) || this.#callsStarting.size > 0) return;
    for (const resolve of this.#callsStarted.splice(0)) resolve();
  }

  #clearCalls(): void {
    this.#callsStarting.clear();
    for (const resolve of this.#callsStarted.splice(0)) resolve();
  }

  /**
   * Waits out a reply that is writing a call, and says whether it was putting
   * a question or plan up: the session is about to park on it, and a send
   * then goes in plain, as it would to a session already asking.
   */
  #replyWritten(): Promise<boolean> {
    if (!this.#replyHasCall) return Promise.resolve(false);
    return new Promise((resolve) => this.#replyEnded.push(resolve));
  }

  #endReply(): void {
    const asked = this.#replyAsks;
    this.#replyHasCall = false;
    this.#replyAsks = false;
    for (const resolve of this.#replyEnded.splice(0)) resolve(asked);
  }

  /**
   * The main reply's partial messages: whether a call is in it. Its text is not
   * sent on: after a narration note the rest of a turn's text is held back and
   * comes whole or in a rush (test/narration-stream-probe.ts).
   */
  #streamed(event: SDKPartialAssistantMessage["event"]): void {
    switch (event?.type) {
      // The earliest word that the session is working. Without it a turn
      // after a cut-in reads idle until its first block is finished, which
      // for a long brief is past the app's 15s quiet-dim.
      case "message_start":
        this.#endReply();
        if (this.state !== "asking" && this.state !== "compacting") this.#setState("running");
        break;

      case "content_block_start": {
        const block = event.content_block;
        if (block?.type === "tool_use") {
          this.#replyHasCall = true;
          if (ASKING_TOOLS.has(block.name)) this.#replyAsks = true;
        }
        break;
      }

      case "message_stop":
        this.#endReply();
        break;
    }
  }

  /**
   * Asked again on every `task_started` while a message waits, because a call
   * made before the task is announced — about the first 3.5s of a foreground
   * Bash — answers true and moves nothing.
   */
  #unblock(): void {
    this.backgroundTasks().catch((error: unknown) =>
      log(`backgroundTasks failed for ${this.key}: ${why(error)}`),
    );
  }

  /**
   * Dates the session by something said *to* it. Nothing echoes an inbound
   * message back, so until the turn produces output the session reads exactly
   * as stale as it did before — and the reaper reads this clock.
   */
  touched(): void {
    this.lastActivityAt = new Date().toISOString();
  }

  async setMode(permissionMode: string): Promise<void> {
    // Refused rather than shrugged off. Recording a mode nothing applied is how
    // the app comes to show one the session is not in.
    const apply = this.#query?.setPermissionMode;
    if (!apply) throw new Error("this SDK cannot change a running session's mode");
    // The SDK's type leaves out `manual`, which the CLI takes.
    await apply.call(this.#query, permissionMode as PermissionMode);
    this.#modeIs(permissionMode);
  }

  /**
   * Moves what the session thinks at, from the next turn on. Refused rather than
   * shrugged off, as the mode is.
   *
   * The same method takes an `outputStyle`, and since SDK 0.3.278 that lands
   * too: the next turn's `system`/`init` frame reports the new style. Through
   * 0.3.241 it was accepted and quietly dropped, with nothing on this wire to
   * say so, which is the reading this comment used to carry. Read it off the
   * next turn, not off `initializationResult()` — that is the cached
   * first-connect answer and does not move; `reinitialize()` would. There is
   * still no style setter beside this one, because the app keeps one app-wide
   * pick bound at launch and no per-session dial: deferred now, not impossible.
   */
  async setEffort(effort: EffortLevel): Promise<void> {
    const apply = this.#query?.applyFlagSettings;
    if (!apply) throw new Error("this SDK cannot change a running session's effort");
    await apply.call(this.#query, { effortLevel: effort });
    if (this.effort === effort) return;
    this.effort = effort;
    this.#emit({ type: "session.effort", key: this.key, effort });
  }

  async interrupt(): Promise<void> {
    await this.#query?.interrupt?.();
  }

  /**
   * Moves every in-flight foreground task to the background — the SDK's own
   * Ctrl+B. Each blocking call comes straight back with the ordinary async
   * launch receipt — `status: "async_launched"`, the agent id beside it — the
   * turn carries on from there, and the task keeps running and settles by
   * `task_notification` exactly as a backgrounded one always did.
   *
   * Shrugged off rather than refused, which is the opposite of `stopTask`
   * beside it. That one is a lever someone pulled and has to be told about;
   * this one runs on the way to delivering a message, and a session that could
   * not be unblocked should still be handed what was said. Every reason it
   * fails is one the message survives: an SDK too old to have the call, and a
   * session started with `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, which throws.
   */
  async backgroundTasks(): Promise<boolean> {
    const background = this.#query?.backgroundTasks;
    if (!background) return false;
    return (await background.call(this.#query)) === true;
  }

  /**
   * Ends one agent and leaves the rest of the session alone. Refused rather
   * than shrugged off, the way a mode change is: the app takes the row down on
   * the transcript's word, so a stop that quietly did nothing would leave the
   * agent running under a row that had stopped saying so.
   */
  async stopTask(taskId: string): Promise<void> {
    const stop = this.#query?.stopTask;
    if (!stop) throw new Error("this SDK cannot stop a single task");
    await stop.call(this.#query, taskId);
  }

  async reconnectMcp(server: string): Promise<void> {
    const reconnect = this.#query?.reconnectMcpServer;
    if (!reconnect) throw new Error("this SDK cannot reconnect an MCP server");
    try {
      await reconnect.call(this.#query, server);
    } finally {
      void this.#reportMcp();
    }
  }

  /**
   * Undocumented on `Query`; `test/mcp-actions-probe.ts` checks it. Resolves
   * once the login has a URL to open, long before anyone has used it, so the
   * readings are asked for again until the server stops waiting on one.
   */
  async loginMcp(server: string): Promise<{ authUrl?: string; reconnects: boolean }> {
    const authenticate = this.#query?.mcpAuthenticate;
    if (!authenticate) throw new Error("this SDK cannot log in to an MCP server");
    const answer = await authenticate.call(this.#query, server);
    this.#mcpLogins.set(server, Date.now() + 5 * 60_000);
    void this.#reportMcp();
    return {
      ...(typeof answer?.authUrl === "string" ? { authUrl: answer.authUrl } : {}),
      reconnects: answer?.callbackExpected !== false,
    };
  }

  get canRename(): boolean {
    return typeof this.#query?.renameSession === "function" && this.sessionId !== null;
  }

  /** Undocumented on `Query`; `test/rename-probe.ts` checks it is still there. */
  async rename(title: string): Promise<void> {
    const rename = this.#query?.renameSession;
    if (!rename) throw new Error("this SDK cannot rename a running session");
    await rename.call(this.#query, title, this.sessionId);
  }

  /** Undocumented on `Query`; `test/side-question-probe.ts` checks what it does. */
  async askSideQuestion(
    question: string,
    history: { question: string; response: string }[],
  ): Promise<string> {
    const ask = this.#query?.askSideQuestion;
    if (!ask) throw new Error("this SDK cannot take a side question");
    const answer = await ask.call(this.#query, question, { history });
    if (!answer?.response) throw new Error("no answer came back");
    return answer.response;
  }

  stop(): void {
    this.#retired = true;
    this.#mcpRetries.stop();
    this.#input.close();
    for (const askId of [...this.#parked.keys()]) this.#withdraw(askId);
  }

  answer(message: Answer): boolean {
    const parked = this.#parked.get(message.askId);
    if (!parked) return false;

    this.#settle(message.askId, decisionFor(message, parked));
    // Every other app connected to this host still has the card up otherwise.
    this.#emit({ type: "ask.withdrawn", askId: message.askId, key: this.key });
    if (message.kind !== "question" && message.optionId === "allow_session" && parked.grant) {
      this.#granted.add(parked.grant);
      for (const [askId, other] of [...this.#parked]) {
        if (other.grant !== parked.grant) continue;
        this.#settle(askId, { behavior: "allow", updatedInput: other.input });
        this.#emit({ type: "ask.withdrawn", askId, key: this.key });
      }
    }
    this.#setState(this.#parked.size > 0 ? "asking" : "running");
    return true;
  }

  // ------------------------------------------------------------- internals

  #park(toolName: string, input: Record<string, unknown>, opts: Parameters<CanUseTool>[2]): Promise<PermissionResult> {
    const askId = randomUUID();
    const suggestions = opts?.suggestions ?? [];
    const drive = screenDrive(toolName, input);
    const kind =
      toolName === "AskUserQuestion"
        ? "question"
        : drive
          ? "takeover"
          : "permission";
    // An MCP `ask` tool's ask carries no suggestions, so the host remembers that grant itself.
    const grant = kind === "permission" && toolName.startsWith("mcp__") ? toolName : null;
    if (grant && this.#granted.has(grant)) {
      return Promise.resolve({ behavior: "allow", updatedInput: input });
    }
    const grantable =
      grant !== null || (toolName !== "ExitPlanMode" && sessionRules(suggestions).length > 0);
    const ask: Ask = {
      type: "ask",
      askId,
      key: this.key,
      kind,
      toolName,
      input,
      options:
        kind === "permission"
          ? permissionOptions(suggestions, grantable)
          : kind === "takeover"
            ? takeoverOptions()
            : [],
      ...(drive ? { screen: drive } : {}),
    };

    return new Promise((resolve) => {
      const signal = opts?.signal;
      const withdraw = () => this.#withdraw(askId);
      const detach = () => signal?.removeEventListener?.("abort", withdraw);
      this.#parked.set(askId, { ask, resolve, input, suggestions, grant, detach });
      signal?.addEventListener?.("abort", withdraw);
      // Ask first: the app announces on the status, and reads the ask for what to say.
      this.#emit(ask);
      this.#setState("asking");
    });
  }

  #withdraw(askId: string): void {
    if (!this.#settle(askId, { behavior: "deny", message: "Withdrawn" })) return;
    this.#emit({ type: "ask.withdrawn", askId, key: this.key });
  }

  #settle(askId: string, decision: PermissionResult): boolean {
    const parked = this.#parked.get(askId);
    if (!parked) return false;
    this.#parked.delete(askId);
    parked.detach();
    parked.resolve(decision);
    return true;
  }

  async #drain(stream: SessionQuery): Promise<void> {
    try {
      for await (const message of stream) {
        stirred();
        // A resume's first prompt can run for minutes before its `init`: a
        // `/compact` says `compacting` at once and `init` only when it is done.
        const isInit = message.type === "system" && message.subtype === "init";
        if (!isInit && this.sessionId === null && this.#options.resume) {
          this.sessionId = this.#options.resume;
          this.#announce([]);
        }
        if (message.type === "stream_event") {
          if (!message.parent_tool_use_id) this.#streamed(message.event);
          continue;
        }
        if (message.type === "system" && message.subtype === "init") {
          this.sessionId = message.session_id;
          this.model = message.model ?? null;
          this.permissionMode = message.permissionMode ?? this.permissionMode;
          this.commands = message.slash_commands ?? null;
          this.mcpServers = mcpReadings(message.mcp_servers) ?? this.mcpServers;
          // The style the CLI *resolved*, which is not always the one asked for
          // — a name matching no file on disk lands somewhere else, and this is
          // the only word for where.
          this.outputStyle = message.output_style ?? this.outputStyle;
          this.#announce(message.tools ?? []);
          this.#setState("running");
          // Not awaited: it is a control round-trip, and `session.init` is the
          // message the app binds the transcript from — one already racing the
          // file the CLI has yet to write.
          void this.#reportStyles();
          void this.#reportMcp();
          void this.#persistName();
          continue;
        }

        // The CLI restates the mode on its own status messages — after a mode
        // change, and after one it made itself, which is what approving a plan
        // is. Without this the app hears about that no sooner than the next
        // turn's `session.init`.
        if (message.type === "system" && "permissionMode" in message && typeof message.permissionMode === "string") {
          this.#modeIs(message.permissionMode);
        }

        // The CLI's only word for a compaction while it runs. Nothing is
        // written to the transcript for the whole stretch — the boundary and
        // the summary land when it is over — so without this the app draws a
        // session at the prompt through a wait that runs to a minute. The
        // status message ends it with `status: null`; the boundary and the
        // result are read as the same word in case that one goes missing.
        if (message.type === "system" && message.subtype === "status") {
          if (message.status === "compacting") this.#setState("compacting");
          else if (this.state === "compacting") this.#setState("running");
        }
        if (
          message.type === "system" &&
          message.subtype === "compact_boundary" &&
          this.state === "compacting"
        ) {
          this.#setState("running");
        }

        // What each call was, so a task can be named by the tool that raised
        // it: nothing on `task_started` says a monitor is a monitor. Subagent
        // turns are read too — the name is all that is wanted, and a task can
        // come from a call one level down.
        if (message.type === "assistant" && !message.parent_tool_use_id) {
          for (const block of message.message?.content ?? []) {
            if (block?.type !== "tool_use" || !block.id || ASKING_TOOLS.has(block.name)) continue;
            if (![...this.#tasks.values()].some((task) => task.toolUseId === block.id)) this.#callsStarting.add(block.id);
          }
        }
        if (message.type === "assistant") {
          let named = false;
          for (const block of message.message?.content ?? []) {
            if (block?.type !== "tool_use" || !block.id || !block.name) continue;
            this.#toolNames.set(block.id, block.name);
            // Measured the other way round on CLI v2.1.269 — the block lands
            // 600ms ahead of the announcement — but a task named nothing counts
            // as work, which is the whole bug this is here to stop.
            for (const task of this.#tasks.values()) {
              if (task.tool !== null || task.toolUseId !== block.id) continue;
              task.tool = block.name;
              named = true;
            }
          }
          if (named) this.#tasksChanged();
        }

        // The two bookends that name a task *and* the call it came from. The
        // SDK's own level signal carries ids alone, so it cannot say which row
        // a task belongs to; this set is kept from the edges instead and sent
        // as a level, which is the shape that survives a missed one.
        if (message.type === "system" && message.subtype === "task_started" && message.task_id) {
          const toolUseId = message.tool_use_id ?? null;
          this.#tasks.set(message.task_id, {
            taskId: message.task_id,
            toolUseId,
            description: message.description ?? null,
            tool: (toolUseId && this.#toolNames.get(toolUseId)) || null,
          });
          this.#tasksChanged();
          this.#callStarted(toolUseId);
          if (this.#messageWaiting) this.#unblock();
        }

        // Whatever became of it — done, failed, or stopped from the app — the
        // task is no longer running and its id is no longer good for anything.
        if (message.type === "system" && message.subtype === "task_notification" && message.task_id) {
          this.turnOwed = true;
          const finished = this.#tasks.get(message.task_id);
          if (finished) {
            this.#tasks.delete(message.task_id);
            if (finished.toolUseId) this.#toolNames.delete(finished.toolUseId);
            this.#tasksChanged();
          }
        }

        if (message.type === "command_lifecycle" && message.state !== "queued") {
          const uuid = message.command_uuid;
          this.#unaccepted = this.#unaccepted.filter((sent) => sent !== uuid);
          if (this.#unaccepted.length === 0) this.#messageWaiting = false;
        }

        if (message.type === "result") {
          void this.#reportMcp();
          // A task is announced in the turn that called for it, so a name the
          // turn is over without is one nothing will ever ask for.
          const kept = new Set([...this.#tasks.values()].map((task) => task.toolUseId));
          for (const id of this.#toolNames.keys()) {
            if (!kept.has(id)) this.#toolNames.delete(id);
          }
          this.#emit({
            type: "session.result",
            key: this.key,
            subtype: message.subtype,
            costUSD: message.total_cost_usd ?? null,
            turns: message.num_turns ?? null,
          });
          // The input stream is still open, so a result ends the turn, not the
          // session; going to `done` here would retire a session mid-conversation.
          this.#messageWaiting = false;
          this.turnOwed = false;
          this.#endReply();
          this.#clearCalls();
          this.#setState("idle");
          continue;
        }

        // A tool result comes only once the reply that called it is over, so
        // a stream that never said `message_stop` doesn't hold a send for
        // every tool the reply ran.
        if (message.type === "user" && !message.parent_tool_use_id) {
          this.#endReply();
          const content = message.message?.content;
          for (const block of Array.isArray(content) ? content : []) {
            if (block?.type === "tool_result") this.#callStarted(block.tool_use_id);
          }
        }

        // A background agent's turns land here too, while the parent is idle with no result coming.
        if (
          (message.type === "assistant" || message.type === "user") &&
          !message.parent_tool_use_id
        ) {
          if (this.state !== "asking" && this.state !== "compacting") this.#setState("running");
        }
      }
      this.#endReply();
      this.#clearCalls();
      // A stream that ran out is the session finishing; one we closed is the host
      // letting go of it, and `done` there posts a Finished notification and lifts
      // a row dismissed yesterday back to the top of the list.
      if (!this.#retired) this.#setState("done");
      this.#emit({
        type: "session.exit",
        key: this.key,
        reason: this.#retired ? "retired" : "ended",
      });
    } catch (error) {
      this.#endReply();
      this.#clearCalls();
      this.#setState("error");
      this.#emit({
        type: "session.exit",
        key: this.key,
        reason: why(error),
      });
    }
    this.turnOwed = false;
    this.#keyFile?.remove();
  }

  /**
   * Posted rather than emitted, like the styles: a server connecting is not
   * the session doing anything, and must not keep it from the reaper.
   */
  async #reportMcp(rechecks = 12): Promise<void> {
    if (this.#mcpRecheck) clearTimeout(this.#mcpRecheck);
    this.#mcpRecheck = null;
    try {
      const raw = await this.#query?.mcpServerStatus?.();
      const servers = mcpReadings(raw);
      if (!raw || !servers) return;
      this.#mcpRetries.update(raw);
      if (JSON.stringify(servers) !== JSON.stringify(this.mcpServers)) {
        this.mcpServers = servers;
        this.#post({ type: "session.mcp", key: this.key, servers });
      }
      for (const [name, until] of this.#mcpLogins) {
        const server = servers.find((server) => server.name === name);
        if (Date.now() >= until || !server || server.status === "connected") this.#mcpLogins.delete(name);
      }
      const loggingIn = this.#mcpLogins.size > 0;
      // A server still connecting settles in the background, often after a
      // short turn is over, and nothing else would ask again until the next.
      const pending = rechecks > 0 && servers.some((server) => server.status === "pending");
      if (!this.#retired && (pending || loggingIn)) {
        this.#mcpRecheck = setTimeout(() => void this.#reportMcp(Math.max(rechecks - 1, 0)), 5000);
        this.#mcpRecheck.unref?.();
      }
    } catch {
      // A control request refused mid-teardown; the last reading stands.
    }
  }

  /** `session.init` comes again every turn; the name is written once. */
  #announce(tools: string[]): void {
    if (this.sessionId === null) return;
    this.#emit({
      type: "session.init",
      key: this.key,
      sessionId: this.sessionId,
      cwd: this.cwd,
      name: this.name,
      origin: this.origin,
      model: this.model,
      permissionMode: this.permissionMode,
      outputStyle: this.outputStyle,
      effort: this.effort,
      tools,
      commands: this.commands,
      mcpServers: this.mcpServers,
    });
  }

  async #persistName(): Promise<void> {
    if (this.#namePersisted || !this.name || this.#options.resume || !this.canRename) return;
    this.#namePersisted = true;
    try {
      await this.rename(this.name);
    } catch (error) {
      log(`naming ${this.key} failed: ${why(error)}`);
    }
  }

  /**
   * The styles this session can see, which is every style there is: built in,
   * in the config directory, and in the project it was started in. Asked for
   * once per session because there is nowhere else to ask — the list is on
   * `initializationResult()` alone, and a picker that has to have a session
   * running to be populated is one the app caches for.
   *
   * A failure is swallowed. This is a picker's contents, not a session's work,
   * and an SDK without the method should cost nothing.
   */
  async #reportStyles(): Promise<void> {
    try {
      const initialized = await this.#query?.initializationResult?.();
      const styles = initialized?.available_output_styles;
      // Posted rather than emitted: this is what the CLI has on disk, not news
      // of the session, and dating one by a picker's contents would keep it
      // away from the reaper for having said nothing.
      if (Array.isArray(styles) && styles.length > 0) {
        this.#post({ type: "host.styles", styles });
      }
    } catch {
      // Nothing to say: the app keeps whatever list it already had.
    }
  }

  #tasksChanged(): void {
    this.#emit({ type: "session.tasks", key: this.key, tasks: [...this.#tasks.values()] });
  }

  /**
   * Announced only on a change, so a status message on every turn does not keep
   * moving the session's clock.
   */
  #modeIs(permissionMode: string): void {
    if (this.permissionMode === permissionMode) return;
    this.permissionMode = permissionMode;
    this.#emit({ type: "session.mode", key: this.key, permissionMode });
  }

  #setState(state: SessionState): void {
    if (this.state === state) return;
    this.state = state;
    this.#emit({ type: "session.status", key: this.key, state });
  }

  /**
   * Every event leaves through here, so a session is dated by the same rule the
   * app dates it by while it is watching: whenever there was news of it.
   */
  #emit(event: Event): void {
    this.lastActivityAt = new Date().toISOString();
    this.#post(event);
  }
}
