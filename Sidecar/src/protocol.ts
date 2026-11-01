/**
 * What crosses the socket, and deliberately nothing else.
 *
 * Transcript content is not on this wire. The SDK writes each session to
 * ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl, which is the same file
 * TranscriptWatcher already reads, so the socket carries only what that file
 * cannot say: a question that is still up, a status that has not been written
 * yet, and the session id that binds a row to its file.
 */

export const PROTOCOL = 1;

/**
 * What a host says it can do, beside the protocol number. The number stays put
 * where a client that doesn't know about a request simply never sends it; this
 * is for the other direction, where a client needs to know before it asks.
 */
export const CAPABILITIES = [
  "rename",
  "side",
  "launch",
  "mcp",
  "apiKey",
] as const;

export type SessionState =
  | "starting"
  | "running"
  | "compacting"
  | "idle"
  | "asking"
  | "done"
  | "error";

/**
 * `question` is AskUserQuestion; `takeover` is a Bash call the host's own
 * PreToolUse hook flagged as driving the user's pointer or keyboard; everything
 * else the model needs cleared is `permission`.
 */
export type AskKind = "question" | "permission" | "takeover";

/**
 * The line of a Bash command that drives the screen, and what in it said so —
 * the `DEX_DRIVES_SCREEN=1` mark or the habit the host's net caught. A
 * takeover's command can be a script with that line at the very bottom, so
 * the card and the bar name this line rather than the command's first.
 */
export interface ScreenDrive {
  line: string;
  match: string;
}

/**
 * Named after ACP's shape rather than the SDK's allow/deny booleans, so the
 * app renders a permission the same way it renders a question — a list of
 * options, one of them picked — and a future ACP mode is a projection of this
 * rather than a rewrite of it. Which options exist is the host's call:
 * `allow_always` is offered only when the SDK supplied a rule to remember.
 */
export type PermissionOptionKind =
  | "allow_once"
  | "allow_always"
  | "reject_once";

export interface AskOption {
  optionId: string;
  name: string;
  kind: PermissionOptionKind;
}

/**
 * The permission modes the host will accept on a `mode` request: the CLI's own
 * `--permission-mode` choices plus `default`, which the flag refuses but a
 * transcript writes. It has to be the whole vocabulary a `start` may carry —
 * `start` is not checked against this, so a name missing here is one a session
 * can be launched in and then never moved out of.
 */
export const PERMISSION_MODES = [
  "default",
  "auto",
  "plan",
  "acceptEdits",
  "manual",
  "dontAsk",
  "bypassPermissions",
] as const;

/**
 * The effort levels a session can be asked for. `max` is on the end of the list
 * the persisted setting stops at: `Settings.effortLevel` excludes it because a
 * settings file may not hold it, while the flag layer this host writes to may.
 */
export const EFFORT_LEVELS = ["low", "medium", "high", "xhigh", "max"] as const;

export function isPermissionMode(value: string): value is (typeof PERMISSION_MODES)[number] {
  return (PERMISSION_MODES as readonly string[]).includes(value);
}

export function isEffortLevel(value: string): value is (typeof EFFORT_LEVELS)[number] {
  return (EFFORT_LEVELS as readonly string[]).includes(value);
}

/**
 * One MCP server as the session's CLI sees it. `status` is the CLI's word
 * (`connected`, `failed`, `needs-auth`, `pending`, `disabled`) and is passed
 * through unread, so a status added later still reaches the app.
 */
export interface McpServerReading {
  name: string;
  status: string;
  error?: string | null;
}

export interface SessionSummary {
  key: string;
  sessionId: string | null;
  cwd: string;
  name: string | null;
  origin: SessionOrigin | null;
  state: SessionState;
  model: string | null;
  permissionMode: string;
  /**
   * What the session is thinking at, where anything has said. Null means nobody
   * asked, and the level is whatever the settings files resolve to — which the
   * host has no way to read back, so it says nothing rather than guessing.
   */
  effort: string | null;
  /**
   * The style the CLI says the session writes in, off its own `system` message.
   * Bound at launch by this app, though the SDK can move one — see
   * `SessionInit.outputStyle`.
   */
  outputStyle: string | null;
  startedAt: string;
  /**
   * When the session last did anything this host had something to say about.
   * The host's to keep rather than the app's: the app can only date a session
   * from when it heard of it, which is the moment it connected, so every
   * resolution against a hosted row died with the app that made it.
   */
  lastActivityAt: string;
  /**
   * The commands this session's CLI will actually run, off its own `init`. The
   * CLI ships plenty it cannot open outside a terminal and simply leaves those
   * out of the list, so this is the only word for which of them are worth
   * offering — a session asked for one of the others answers with a refusal
   * that costs a turn.
   *
   * Replayed with the welcome because `init` is emitted per turn: a session
   * idle since before the app connected would otherwise have none until it is
   * next spoken to.
   *
   * Null rather than empty until one has arrived. A session reports itself from
   * the moment `start` answers, which is before its first `init`, and an empty
   * array there is a positive claim that it will run nothing — the app would
   * grey every row of a session whose commands simply hadn't been named yet.
   */
  commands: string[] | null;
  /** See `SessionInit.mcpServers`. Absent from a host that predates it. */
  mcpServers?: McpServerReading[] | null;
}

// ---------------------------------------------------------------- app → host

export interface Hello {
  id: string;
  type: "hello";
  protocol: number;
  /**
   * Whether this client takes `launch` events.
   */
  launches?: boolean;
}

/**
 * The app's answer to a `launch`: the key of the session it started, or why
 * it didn't.
 */
export interface Launched {
  id: string;
  type: "launched";
  launchId: string;
  key?: string;
  error?: string;
}

/**
 * What started a session that wasn't started by hand. Background watchers
 * (launchd jobs writing `~/.claude/dex/watchers/<name>.json`) send `watcher`; a
 * session started by another one's `start_session` carries that one's key as
 * `parent`. The app marks and filters rows by it.
 */
export interface SessionOrigin {
  watcher?: string;
  reason?: string;
  parent?: string;
}

export interface Start {
  id: string;
  type: "start";
  cwd: string;
  prompt: string;
  model?: string;
  permissionMode?: string;
  /**
   * Written to the transcript as the session's title on a fresh start, so it
   * outranks the CLI's generated one. Not on a resume: the app resumes with the
   * name it last read, which would freeze the CLI's title as a rename.
   */
  name?: string;
  origin?: SessionOrigin;
  /**
   * Omitted, a session loads settings the way the CLI does, allow rules
   * included — which is what the app wants and what makes a pre-approved tool
   * skip the ask entirely. `[]` is the clean room a test needs.
   */
  settingSources?: ("user" | "project" | "local")[];
  /**
   * How the session writes, by the name of a style on disk. Sent at launch or
   * never, which is now an app decision rather than a limit: since SDK 0.3.278
   * `applyFlagSettings` takes an `outputStyle` and the next turn writes in it
   * (measured against 0.3.241, the same call accepted it and changed nothing).
   * `/output-style` typed at a hosted session answers `Output style set to
   * <name>` and writes `outputStyle` to the cwd's `.claude/settings.local.json`,
   * but this flag layer outranks that file, so the style in force does not move
   * on a session that was started with one. The app keeps its single app-wide
   * pick for now, so unlike the mode there is still no request on this wire to
   * move a style — deferred, not impossible.
   *
   * Omitted means whatever the settings files resolve to, which is what the
   * app's own picker calls Default.
   */
  outputStyle?: string;
  /**
   * How hard the session thinks. Unlike the style this one does move, so the
   * same name is also an `effort` request below.
   */
  effort?: string;
  /**
   * The transcript id of a conversation to pick up rather than begin. It keeps
   * that id rather than forking to a new one, so a row bound to the file stays
   * bound to it.
   *
   * `prompt` is still required and still goes in: a resumed session sits silent
   * until it is handed something to say, so one started with nothing would never
   * reach `session.init` and never become a row.
   */
  resume?: string;
  /**
   * The key to file this session under, rather than one of the host's own
   * invention. It is how a resumed conversation comes back as the row it was:
   * the app names rows by this, so a host handing back a fresh key would put
   * the resumed session in the list as a stranger, having lost its place and
   * whatever you had said about it.
   *
   * Refused if a live session already holds it — two sessions under one key is
   * one of them unreachable.
   */
  key?: string;
  /**
   * The session's only credential, read by its CLI through `apiKeyHelper`,
   * which outranks a stored claude.ai login and stays out of the environment
   * the session's tools inherit (`api-key-over-login-probe.ts`). Omitted, the
   * CLI signs in however it is set up to. Kept in a file only while the
   * session runs, so each resume sends it again.
   */
  apiKey?: string;
}

export interface Send {
  id: string;
  type: "send";
  key: string;
  text: string;
}

/**
 * The app answers in its own terms — labels the user picked, or allow/deny —
 * and the host turns that into whatever shape the SDK wants this week. Keeping
 * the SDK's decision shape on this side of the socket is most of the point of
 * having a host at all.
 */
export type Answer =
  | {
      id: string;
      type: "answer";
      askId: string;
      kind: "question";
      answers: Record<string, string | string[]>;
      /** What was written beside a pick, keyed by the question it belongs to. */
      annotations?: Record<string, { notes?: string }>;
      /**
       * Said instead of picking. The CLI records this as the whole of the reply
       * and writes nothing else, so it never arrives with answers beside it.
       */
      response?: string;
    }
  | {
      id: string;
      type: "answer";
      askId: string;
      kind: "permission";
      optionId: string;
      /** Sent with a rejection to tell the model what to do instead. */
      message?: string;
    };

export interface Mode {
  id: string;
  type: "mode";
  key: string;
  permissionMode: string;
}

/**
 * Moves a running session's effort. `applyFlagSettings` takes this and the next
 * turn runs at it. The same call takes an `outputStyle` and, since SDK 0.3.278,
 * moves that too — it dropped one silently through 0.3.241 — so the style has no
 * request of its own here by the app's choice rather than the SDK's: one
 * app-wide pick, bound at launch.
 */
export interface Effort {
  id: string;
  type: "effort";
  key: string;
  effort: string;
}

/**
 * What a session started in `cwd` would resolve its style and effort to, if the
 * app sent neither. It is what the pickers' Default row is named after, the way
 * the model picker's is named after the model the CLI would pick.
 *
 * Keyed by directory because the answer is a merge and a project may hold
 * settings of its own — the same app, pointed at two folders, has two Defaults.
 */
export interface ResolveDefaults {
  id: string;
  type: "defaults";
  cwd: string;
}

export interface Interrupt {
  id: string;
  type: "interrupt";
  key: string;
}

export interface Stop {
  id: string;
  type: "stop";
  key: string;
}

/**
 * Ends one agent, leaving the session and everything else it has out alone.
 * `interrupt` is the other lever and a blunter one: it ends the whole turn, and
 * takes any agent the turn is waiting on with it.
 */
export interface StopTask {
  id: string;
  type: "stopTask";
  key: string;
  taskId: string;
}

/** Asks the session to connect to one of its MCP servers again. */
export interface McpReconnect {
  id: string;
  type: "mcpReconnect";
  key: string;
  server: string;
}

/**
 * Starts one MCP server's OAuth login. The reply carries `authUrl` for the app
 * to open; the CLI waits on its own localhost callback and reconnects itself.
 */
export interface McpLogin {
  id: string;
  type: "mcpLogin";
  key: string;
  server: string;
}

/** Lands as a `custom-title` record, hosted here or not. */
export interface Rename {
  id: string;
  type: "rename";
  sessionId: string;
  title: string;
}

/**
 * A side question: the CLI's `/btw`, asked of a live session's conversation.
 * Answered without tools, never written to the transcript, and never heard by
 * the session's later turns. Safe mid-turn. `history` is the earlier questions
 * and answers of the same aside, which the CLI otherwise forgets.
 */
export interface SideQuestion {
  id: string;
  type: "side";
  key: string;
  question: string;
  history?: { question: string; response: string }[];
}

export type Request =
  | Hello
  | Launched
  | Start
  | Send
  | Answer
  | Mode
  | Effort
  | ResolveDefaults
  | Interrupt
  | Stop
  | StopTask
  | McpReconnect
  | McpLogin
  | Rename
  | SideQuestion;

// ---------------------------------------------------------------- host → app

export interface Reply {
  type: "reply";
  id: string;
  ok: boolean;
  key?: string;
  error?: string;
  /** `side`, the answer. */
  response?: string;
}

export interface Welcome {
  type: "welcome";
  protocol: number;
  host: string;
  /** What the host process loaded, frozen at start — not what is on disk now. */
  sdk: string;
  /**
   * What a host started this second would load. Newer than `sdk` means a build
   * has landed under a host that is still running the one before it, which the
   * app has no other way to see: the host outlives it, and the CLI binary beside
   * the SDK is spawned per session and so moves without it.
   */
  sdkOnDisk: string;
  /**
   * The commit this host's bundle was built from — make-app.sh writes it as
   * build.json beside the sidecar. Null from a checkout, which has no stamp.
   * The app compares it to its own bundle's commit: different means the host
   * predates the app talking to it, which the SDK pair beside it only notices
   * when the pin happened to move.
   */
  build: string | null;
  /**
   * Whether the host is holding work that would be lost if it were stopped now
   * — a turn in flight, a parked question, or a background task. Read off the
   * host's own sessions as the welcome is built, so an app deciding to replace
   * a stale host has an answer that doesn't race the `session.tasks` levels
   * sent behind this welcome.
   */
  busy: boolean;
  /**
   * What this host can do beyond the sessions themselves. A client talking to
   * a host that predates one has to do without it rather than wait on replies
   * that will never come, and absence here is the only warning it gets.
   */
  capabilities: string[];
  /**
   * The host's own `~/.claude`, after `CLAUDE_CONFIG_DIR`.
   */
  configDir: string;
  /**
   * The host's own `os.hostname()`.
   */
  hostname: string;
  /** What a `mode` request will accept, so the badge needs no generated table. */
  modes: string[];
  /** What an `effort` request will accept, for the same reason. */
  efforts: string[];
  /**
   * Every output style the CLI has — built in, in the config directory, and in
   * a project's own. Learned from a session rather than known: the only place
   * the list exists is `initializationResult()`, which needs a running query, so
   * this is whatever the newest session reported and empty on a host that has
   * not started one. The app keeps its own copy for that reason.
   */
  outputStyles: string[];
  /**
   * The host's own pid. A hosted session has no process of its own for the app
   * to point at, and a row with no pid is one the transcript watcher skips.
   */
  pid: number;
  sessions: SessionSummary[];
  /** Asks still parked when the app reconnects, so a question raised while it was closed is on screen at launch. */
  pending: Ask[];
}

export interface SessionInit {
  type: "session.init";
  key: string;
  sessionId: string;
  cwd: string;
  /**
   * The start's name and origin. Here as well as on the summary because an app
   * already connected when another client starts a session never sees that
   * session's summary.
   */
  name: string | null;
  origin: SessionOrigin | null;
  /**
   * Fixed for the session's life. The SDK cannot move the main conversation's
   * model once it is running, so unlike the terminal — where `/model` mid-run
   * works — the picker either binds at launch or restarts the session under a
   * resume. There is deliberately no request on this wire to change it.
   */
  model: string | null;
  permissionMode: string;
  /**
   * Bound at launch, unlike the model for a softer reason than it looks: since
   * SDK 0.3.278 `applyFlagSettings` does move a running session's style, and
   * the app simply doesn't offer that yet — one app-wide pick, no per-session
   * dial. Read off the CLI's own `system` message, so it names the style that
   * was actually resolved rather than the one that was asked for — a name that
   * matches no file on disk resolves to something else and this is the only
   * word for which, and it is also what would report a style that had moved.
   */
  outputStyle: string | null;
  /**
   * What the session was started at, or null where it was started at whatever
   * the settings files resolve to. Unlike the two above this one moves — the
   * dial's `session.effort` says so — and this is the only word an app that was
   * already connected when the session started will ever get: the summary
   * carrying it rides on the welcome, which such an app has long since had.
   */
  effort: string | null;
  tools: string[];
  commands: string[] | null;
  /** Off the `init` frame; `session.mcp` carries it on as servers finish connecting. */
  mcpServers: McpServerReading[] | null;
}

/**
 * The session's MCP servers, whenever their statuses move. A level rather than
 * a change: the app replaces what it holds. Sent from `mcpServerStatus()` after
 * init and after each turn, since a server still `pending` at init connects
 * (or fails) in the background and nothing else says so.
 */
export interface SessionMcp {
  type: "session.mcp";
  key: string;
  servers: McpServerReading[];
}

/**
 * What a session is thinking at, whenever that moves. Emitted on the host's own
 * word rather than the CLI's: nothing restates the effort the way a `system`
 * message restates the mode, so what this carries is the level `applyFlagSettings`
 * accepted — and a level the CLI silently downgraded for the model would not be
 * caught here. `max` on a model that has none is the case to watch.
 */
export interface SessionEffort {
  type: "session.effort";
  key: string;
  effort: string;
}

/**
 * The styles a session found on disk, sent when the set the host holds changes.
 * Its own event rather than a field on `session.init` because it arrives on a
 * control round-trip: waiting for it would hold back the message the app binds
 * a row's transcript from, and that message is already racing the file.
 */
export interface OutputStyles {
  type: "host.styles";
  styles: string[];
}

/**
 * What Default means for a directory: the settings cascade merged by the CLI's
 * own engine, with nothing of the app's in it.
 *
 * Deliberately not what the last session ran at. Anything the app sends goes in
 * the flag layer, which sits above every file here, so a session's own reading
 * would answer "whatever you last picked" — where the row wants to say what you
 * get if you pick nothing.
 *
 * Either field is null where the cascade sets it nowhere and the CLI falls back
 * to something of its own. Null is the honest answer there: the app says
 * Default and stops, rather than naming a level nothing on disk asked for.
 */
export interface HostDefaults {
  type: "host.defaults";
  cwd: string;
  outputStyle: string | null;
  effort: string | null;
  /** Absent when there was no resolver to ask. Absence must read as "nobody
   * answered", never as "no file names one": the model chip asserts a name on
   * the second and has to stay quiet on the first. */
  model?: string | null;
  /** Every file that names an effort, highest precedence first. `effort` is
   * the merged top-level key, which the CLI no longer applies to every model:
   * a per-model entry beats it, and one in the user's own file reaches only
   * the models released before `/effort` went per-model. The app picks the
   * level for a model off this. Absent on a host from before it. */
  efforts?: EffortSource[];
}

export interface EffortSource {
  source: string;
  effort: string | null;
  models: Record<string, string>;
}

export interface SessionStatus {
  type: "session.status";
  key: string;
  state: SessionState;
}

/**
 * The mode the CLI says the session is in, whenever that stops matching what
 * the host last recorded. The only word for a change the CLI made itself —
 * approving a plan moves the session out of plan mode, and `session.init`
 * carries the news no sooner than the next turn.
 */
export interface SessionMode {
  type: "session.mode";
  key: string;
  permissionMode: string;
}

export interface Ask {
  type: "ask";
  askId: string;
  key: string;
  kind: AskKind;
  toolName: string;
  input: unknown;
  /**
   * Empty on a question, whose choices live inside `input.questions`; on a
   * permission this is the full set of ways to answer, so the app never has to
   * work out whether "always" is on the table.
   */
  options: AskOption[];
  /** On a `takeover`, which line of the command the host read as driving. */
  screen?: ScreenDrive;
}

/** The session is no longer holding the ask: answered, by any client, or withdrawn. */
export interface AskWithdrawn {
  type: "ask.withdrawn";
  askId: string;
  key: string;
}

/**
 * One piece of work the session has running that can be ended on its own — an
 * agent, or anything else the CLI files as a task.
 *
 * `toolUseId` is the whole point of carrying this. The transcript knows an agent
 * by the call that spawned it and knows nothing about task ids, so without it
 * the app has a stoppable task and no way to say which row it belongs to.
 * Nothing is stoppable where it is missing.
 */
export interface RunningTask {
  taskId: string;
  toolUseId: string | null;
  description: string | null;
  /**
   * The name of the tool call the task came from, where one has been seen.
   * `Monitor` is the one the app reads: a watcher sits in the set for its whole
   * timeout with the turn long over, so a row that counted it would spin.
   */
  tool: string | null;
}

/**
 * Everything the session has running, whenever that set changes — replace what
 * you had rather than pairing starts with finishes. Sent as a level for the
 * reason the SDK sends its own as one: a missed edge would leave a Stop button
 * on a row whose agent came back ten minutes ago, and pressing it would end a
 * task id that no longer exists.
 *
 * Not the SDK's `background_tasks_changed`, which is a level too but carries no
 * `tool_use_id` — the host keeps this set from the `task_started` and
 * `task_notification` bookends, which do.
 */
export interface SessionTasks {
  type: "session.tasks";
  key: string;
  tasks: RunningTask[];
}

export interface SessionResult {
  type: "session.result";
  key: string;
  subtype: string;
  costUSD: number | null;
  turns: number | null;
}

export interface SessionExit {
  type: "session.exit";
  key: string;
  reason: string;
}

/**
 * A hosted session asked for another session. Sent to one local app, which
 * starts it the way its composer would — the model, effort and brief are
 * decided there — and answers with `launched`.
 */
export interface Launch {
  type: "launch";
  launchId: string;
  cwd: string;
  prompt: string;
  name?: string;
  /** The asking session's key. */
  parent: string;
}

export type Event =
  | Reply
  | Launch
  | Welcome
  | SessionInit
  | SessionStatus
  | SessionMode
  | SessionEffort
  | SessionMcp
  | OutputStyles
  | HostDefaults
  | SessionTasks
  | Ask
  | AskWithdrawn
  | SessionResult
  | SessionExit;
