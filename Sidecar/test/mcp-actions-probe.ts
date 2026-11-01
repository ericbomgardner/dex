/**
 * What a session's MCP controls do: reconnect a server, and sign one in.
 *
 *   node test/mcp-actions-probe.ts
 *
 * A chip that names a failed or `needs-auth` server is only half useful if
 * nothing can be done about it. The SDK's `Query` has two controls for that:
 * `reconnectMcpServer(name)`, typed, and `mcpAuthenticate(name, redirectUri?)`,
 * which `sdk.mjs` has and `sdk.d.ts` doesn't. This checks that a server that
 * read `failed` reads `connected` after a reconnect once something listens,
 * with no turn in between; what a reconnect of an unknown name does; that an
 * OAuth-protected http server reads `needs-auth`; what `mcpAuthenticate`
 * answers with no redirect URI; and that once the browser's redirect reaches
 * the CLI's callback port the server reads `connected` without a reconnect.
 * Last, that reconnecting a server whose http server was closed and reopened
 * resolves.
 *
 * Servers, all in this process: `late`, an http server on a port nothing
 * listens on until after the first turn; `locked`, an http server that answers
 * 401 until it sees the token its own fake authorization server handed out.
 * The probe plays the browser by fetching the redirect URI itself. The token
 * the CLI stores for `locked` is cleared with `mcpClearAuth` before the end.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createServer as createNetServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-mcp-actions-"));

const freePort = () =>
  new Promise<number>((resolve) => {
    const server = createNetServer().listen(0, "127.0.0.1", () => {
      const port = (server.address() as any).port;
      server.close(() => resolve(port));
    });
  });

function answerMcp(req: IncomingMessage, res: ServerResponse, body: string): void {
  if (req.method !== "POST") return void res.writeHead(405).end();
  const m = JSON.parse(body);
  if (m.id === undefined) return void res.writeHead(202).end();
  const result =
    m.method === "initialize"
      ? { protocolVersion: m.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "probe", version: "0" } }
      : m.method === "tools/list"
        ? { tools: [] }
        : undefined;
  const reply = result ? { jsonrpc: "2.0", id: m.id, result } : { jsonrpc: "2.0", id: m.id, error: { code: -32601, message: "no" } };
  res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(reply));
}

const readBody = (req: IncomingMessage) =>
  new Promise<string>((resolve) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => resolve(body));
  });

const latePort = await freePort();
const lateServer = () => createServer(async (req, res) => answerMcp(req, res, await readBody(req)));
const listenOn = (server: ReturnType<typeof createServer>, port: number) =>
  new Promise<void>((resolve) => server.listen(port, "127.0.0.1", () => resolve()));
const shut = (server: ReturnType<typeof createServer>) =>
  new Promise<void>((resolve) => {
    server.close(() => resolve());
    server.closeAllConnections();
  });

const token = `probe-token-${Date.now()}`;
const code = `probe-code-${Date.now()}`;
const oauthLog: string[] = [];
let tokenIssuedAt = 0;
const locked = createServer(async (req, res) => {
  const body = await readBody(req);
  const url = new URL(req.url ?? "/", base());
  oauthLog.push(`${req.method} ${url.pathname}`);
  const json = (status: number, value: unknown) => res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(value));
  if (url.pathname.startsWith("/.well-known/oauth-protected-resource")) {
    return json(200, { resource: `${base()}/mcp`, authorization_servers: [base()], bearer_methods_supported: ["header"] });
  }
  if (url.pathname.startsWith("/.well-known/oauth-authorization-server") || url.pathname.startsWith("/.well-known/openid-configuration")) {
    return json(200, {
      issuer: base(),
      authorization_endpoint: `${base()}/authorize`,
      token_endpoint: `${base()}/token`,
      registration_endpoint: `${base()}/register`,
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
    });
  }
  if (url.pathname === "/register" && req.method === "POST") {
    return json(201, { ...JSON.parse(body || "{}"), client_id: "probe-client", client_id_issued_at: Math.floor(Date.now() / 1000) });
  }
  if (url.pathname === "/token" && req.method === "POST") {
    const form = new URLSearchParams(body);
    if (form.get("grant_type") === "authorization_code" && form.get("code") === code) {
      tokenIssuedAt = Date.now();
      return json(200, { access_token: token, token_type: "Bearer", expires_in: 3600 });
    }
    return json(400, { error: "invalid_grant" });
  }
  if (url.pathname === "/mcp") {
    if (req.headers.authorization !== `Bearer ${token}`) {
      return void res
        .writeHead(401, { "www-authenticate": `Bearer resource_metadata="${base()}/.well-known/oauth-protected-resource"` })
        .end("unauthorized");
    }
    return answerMcp(req, res, body);
  }
  res.writeHead(404).end();
});
await new Promise<void>((resolve) => locked.listen(0, "127.0.0.1", () => resolve()));
const lockedPort = (locked.address() as any).port as number;
const base = () => `http://127.0.0.1:${lockedPort}`;

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const outcome = async (run: () => Promise<unknown>) => {
  try {
    return { resolved: true, value: await run() };
  } catch (error) {
    return { resolved: false, error: error instanceof Error ? error.message : String(error) };
  }
};

let late: ReturnType<typeof createServer> | undefined;
try {
  let finish = () => {};
  const done = new Promise<void>((resolve) => (finish = resolve));
  async function* input() {
    yield { type: "user", message: { role: "user", content: "Say ok." }, parent_tool_use_id: null, session_id: "" };
    await done;
  }
  const session = query({
    prompt: input() as any,
    options: {
      cwd: scratch,
      model: "haiku",
      strictMcpConfig: true,
      mcpServers: {
        late: { type: "http", url: `http://127.0.0.1:${latePort}/mcp` },
        locked: { type: "http", url: `${base()}/mcp` },
      },
    } as any,
  });
  const loose = session as any;
  const statuses = async () =>
    Object.fromEntries((await session.mcpServerStatus()).map((server: any) => [server.name, server.status]));
  const errors = async () =>
    Object.fromEntries((await session.mcpServerStatus()).map((server: any) => [server.name, server.error]));
  const waitFor = async (name: string, status: string, ms: number) => {
    const start = Date.now();
    while (Date.now() - start < ms) {
      if ((await statuses())[name] === status) return Date.now() - start;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    return undefined;
  };

  // Not `for await … break`: leaving that loop closes the query, and every
  // control below is asked between turns.
  while (true) {
    const { value: message, done: ended } = await session.next();
    if (ended || message.type === "result") break;
  }

  const first = await statuses();
  console.log(`  after turn 1: ${JSON.stringify(first)} errors ${JSON.stringify(await errors())}`);

  check(first.late === "failed", "an http server nothing listens on reads failed");
  late = lateServer();
  await listenOn(late, latePort);
  await new Promise((resolve) => setTimeout(resolve, 1000));
  const beforeReconnect = (await statuses()).late;
  console.log(`  late 1s after its server started, before any reconnect: ${beforeReconnect}`);
  let started = Date.now();
  const reconnect = await outcome(() => session.reconnectMcpServer("late"));
  const reconnectMs = Date.now() - started;
  const afterReconnect = (await statuses()).late;
  console.log(`  reconnectMcpServer("late"): ${JSON.stringify(reconnect)} in ${reconnectMs}ms, then ${afterReconnect}`);
  check(reconnect.resolved, "reconnectMcpServer resolves for a failed server that is now listening");
  check(afterReconnect === "connected", "the server reads connected right after the reconnect, with no new turn");

  const unknown = await outcome(() => session.reconnectMcpServer("no-such-server"));
  console.log(`  reconnectMcpServer("no-such-server"): ${JSON.stringify(unknown)}`);
  check(!unknown.resolved, "reconnectMcpServer throws for a name that isn't configured");

  check(first.locked === "needs-auth", "an http server answering 401 with resource metadata reads needs-auth");
  check(typeof loose.mcpAuthenticate === "function", "mcpAuthenticate is a function on the Query at runtime");
  if (typeof loose.mcpAuthenticate === "function") {
    const auth = await outcome(() => loose.mcpAuthenticate("locked"));
    console.log(`  mcpAuthenticate("locked"): ${JSON.stringify(auth)}`);
    const response: any = auth.resolved ? auth.value : undefined;
    check(
      response?.requiresUserAction === true &&
        response?.callbackExpected === true &&
        response?.redirectScheme === "localhost" &&
        typeof response?.authUrl === "string" &&
        typeof response?.callbackPort === "number" &&
        typeof response?.state === "string",
      "mcpAuthenticate answers {authUrl, requiresUserAction: true, callbackExpected: true, redirectScheme: localhost, callbackPort, state}",
    );
    const keys = response ? Object.keys(response).sort() : [];
    check(
      JSON.stringify(keys) === JSON.stringify(["authUrl", "callbackExpected", "callbackPort", "redirectScheme", "requiresUserAction", "state"]),
      `mcpAuthenticate's response has exactly those keys (got ${keys.join(", ")})`,
    );
    if (typeof response?.authUrl === "string") {
      const authUrl = new URL(response.authUrl);
      const redirect = authUrl.searchParams.get("redirect_uri") ?? "";
      const state = authUrl.searchParams.get("state") ?? "";
      console.log(`  authUrl: ${authUrl.origin}${authUrl.pathname} with ${[...authUrl.searchParams.keys()].join(", ")}`);
      console.log(`  redirect_uri ${redirect}; state in url ${state === response.state ? "matches" : "differs from"} response.state`);
      check(authUrl.origin === base() && authUrl.pathname === "/authorize", "authUrl is the authorization server's authorize endpoint");
      check(redirect.startsWith(`http://localhost:${response.callbackPort}/`), "the redirect_uri is on localhost at callbackPort");

      const callback = new URL(redirect);
      callback.searchParams.set("code", code);
      callback.searchParams.set("state", state);
      started = Date.now();
      const browser = await outcome(async () => {
        const res = await fetch(callback);
        return { status: res.status, body: (await res.text()).slice(0, 120) };
      });
      console.log(`  browser redirect to the callback: ${JSON.stringify(browser)}`);
      const connectedAfter = await waitFor("locked", "connected", 30_000);
      const tokenAfter = tokenIssuedAt ? tokenIssuedAt - started : undefined;
      console.log(`  token issued ${tokenAfter}ms after the redirect; locked read connected ${connectedAfter}ms after it; now ${(await statuses()).locked}`);
      check(tokenIssuedAt > 0, "the CLI traded the code for a token at the token endpoint");
      check(connectedAfter !== undefined, "after the callback the server reads connected within 30s, with no reconnect call");
    }
  }

  check((await statuses()).late === "connected", "late still reads connected before its server is bounced");
  await shut(late);
  late = lateServer();
  await listenOn(late, latePort);
  const bouncedBefore = (await statuses()).late;
  started = Date.now();
  const bounced = await outcome(() => session.reconnectMcpServer("late"));
  const bouncedAfter = (await statuses()).late;
  console.log(`  late closed and reopened reads ${bouncedBefore}; reconnectMcpServer: ${JSON.stringify(bounced)} in ${Date.now() - started}ms, then ${bouncedAfter}`);
  check(bounced.resolved && bouncedAfter === "connected", "reconnecting a connected server whose http server was closed and reopened resolves and reads connected");

  await shut(late);
  const whileClosed = await outcome(() => session.reconnectMcpServer("late"));
  console.log(`  reconnectMcpServer("late") with its server closed: ${JSON.stringify(whileClosed)}, then ${(await statuses()).late}`);
  check(!whileClosed.resolved, "reconnecting a server nothing listens on throws");

  if (typeof loose.mcpClearAuth === "function") {
    const cleared = await outcome(() => loose.mcpClearAuth("locked"));
    console.log(`  mcpClearAuth("locked"): ${JSON.stringify(cleared)}, then ${(await statuses()).locked}`);
  }

  finish();
  session.close?.();
  console.log(`  oauth server saw: ${[...new Set(oauthLog)].join(", ")}`);
} finally {
  if (late) await shut(late);
  await shut(locked);
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length ? `\nmcp-actions: ${failures.length} check(s) failed` : "\nmcp-actions: all checks passed");
process.exit(failures.length ? 1 : 0);
