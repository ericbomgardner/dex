/**
 * Whether `reconnectMcpServer` reads the server's config again, and whether
 * the host reconnects a failed http server on its own once it listens.
 *
 *   node test/mcp-reconnect-config-probe.ts
 *
 * The host retries a server that failed to connect (`#retryMcp`), so it
 * matters what a reconnect connects to: the URL the session started with, or
 * whatever the config file says now. The server here, `moved`, comes from a
 * project `.mcp.json` in a scratch folder, approved by that folder's
 * `.claude/settings.local.json`. After the first turn the probe rewrites
 * `.mcp.json` to a second port, reads the status, reconnects with nothing
 * listening, then listens on the second port and reconnects again.
 *
 * Then a `HostedSession` of its own, against the same kind of server on a port
 * nothing listens on: the probe starts listening after the turn and waits for
 * the host to post `connected` with nobody pressing Reconnect, and checks that
 * neither a failed reconnect nor the retries moved `lastActivityAt`, the
 * reaper's clock. A second server
 * that answers 404 must stay failed and never be reconnected.
 */

import { query, type McpServerStatus } from "@anthropic-ai/claude-agent-sdk";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createServer as createNetServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { mcpRetryTarget } from "../src/mcp.ts";
import { HostedSession } from "../src/session.ts";
import type { Event } from "../src/protocol.ts";

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

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

const hits = new Map<number, number>();
const mcpServer = (port: number) =>
  createServer((req, res) => {
    hits.set(port, (hits.get(port) ?? 0) + 1);
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => answerMcp(req, res, body));
  });
const listenOn = (server: ReturnType<typeof createServer>, port: number) =>
  new Promise<void>((resolve) => server.listen(port, "127.0.0.1", () => resolve()));
const shut = (server: ReturnType<typeof createServer>) =>
  new Promise<void>((resolve) => {
    server.close(() => resolve());
    server.closeAllConnections();
  });

const outcome = async (run: () => Promise<unknown>) => {
  try {
    return { resolved: true, value: await run() };
  } catch (error) {
    return { resolved: false, error: error instanceof Error ? error.message : String(error) };
  }
};

const scratch = realpathSync(mkdtempSync(path.join(tmpdir(), "dex-mcp-reconnect-")));
const writeMcpJson = (servers: Record<string, string>) =>
  writeFileSync(
    path.join(scratch, ".mcp.json"),
    JSON.stringify({ mcpServers: Object.fromEntries(Object.entries(servers).map(([name, url]) => [name, { type: "http", url }])) }),
  );
mkdirSync(path.join(scratch, ".claude"));
writeFileSync(path.join(scratch, ".claude", "settings.local.json"), JSON.stringify({ enableAllProjectMcpServers: true }));

const listening: ReturnType<typeof createServer>[] = [];
try {
  console.log("mcpRetryTarget");
  const failed = (url: string, error = "ECONNREFUSED: Unable to connect. Is the computer able to access the url?"): McpServerStatus => ({
    name: "s",
    status: "failed",
    error,
    config: { type: "http", url },
  });
  check(JSON.stringify(mcpRetryTarget(failed("http://localhost:7123/mcp"))) === JSON.stringify({ host: "localhost", port: 7123 }), "a refused http server is retried at its host and port");
  check(mcpRetryTarget(failed("https://example.com/mcp"))?.port === 443, "an https URL with no port is retried on 443");
  check(mcpRetryTarget({ ...failed("http://localhost:7123/sse"), config: { type: "sse", url: "http://localhost:7123/sse" } }) !== null, "an sse server is retried too");
  check(mcpRetryTarget({ ...failed("http://localhost:7123/mcp"), status: "needs-auth" }) === null, "a needs-auth server is not retried");
  check(mcpRetryTarget({ ...failed("http://x"), config: { type: "stdio", command: "x" } }) === null, "a stdio server is not retried");
  check(mcpRetryTarget(failed("http://localhost:7123/mcp", "HTTP 404: Not Found")) === null, "a server that answered with an error is not retried");
  check(mcpRetryTarget(failed("http://localhost:7123/mcp", "Error POSTing to endpoint: Unable to connect to database")) === null, "a 500 whose body sounds like a refusal is not retried");
  check(mcpRetryTarget({ ...failed("http://localhost:7123/mcp"), error: undefined }) === null, "a failure with no error is not retried");

  console.log("\nreconnectMcpServer after .mcp.json moves the server");
  const firstPort = await freePort();
  const secondPort = await freePort();
  writeMcpJson({ moved: `http://127.0.0.1:${firstPort}/mcp` });

  let finish = () => {};
  const done = new Promise<void>((resolve) => (finish = resolve));
  async function* input() {
    yield { type: "user", message: { role: "user", content: "Say ok." }, parent_tool_use_id: null, session_id: "" };
    await done;
  }
  const session = query({
    prompt: input() as any,
    options: { cwd: scratch, model: "haiku", settingSources: ["project", "local"] } as any,
  });
  const reading = async () => (await session.mcpServerStatus()).find((server: any) => server.name === "moved") as any;
  while (true) {
    const { value: message, done: ended } = await session.next();
    if (ended || message.type === "result") break;
  }

  const first = await reading();
  console.log(`  after turn 1: ${first?.status} ${first?.error ?? ""} config ${JSON.stringify(first?.config)}`);
  check(first?.status === "failed", "a project .mcp.json http server nothing listens on reads failed");

  writeMcpJson({ moved: `http://127.0.0.1:${secondPort}/mcp` });
  await sleep(1_000);
  const rewritten = await reading();
  console.log(`  .mcp.json rewritten to :${secondPort}, before any reconnect: ${rewritten?.status} config ${JSON.stringify(rewritten?.config)}`);
  check(rewritten?.config?.url === `http://127.0.0.1:${firstPort}/mcp`, "mcpServerStatus still reports the URL the session started with until a reconnect");

  const stillDown = await outcome(() => session.reconnectMcpServer("moved"));
  const afterDown = await reading();
  console.log(`  reconnect with nothing on either port: ${JSON.stringify(stillDown)}, then ${afterDown?.status} config ${JSON.stringify(afterDown?.config)}`);
  check(!stillDown.resolved && afterDown?.status === "failed", "a reconnect with nothing listening throws and leaves the server failed");

  const second = mcpServer(secondPort);
  listening.push(second);
  await listenOn(second, secondPort);
  const toSecond = await outcome(() => session.reconnectMcpServer("moved"));
  const afterSecond = await reading();
  console.log(
    `  :${secondPort} listening: reconnect ${JSON.stringify(toSecond)}, then ${afterSecond?.status} config ${JSON.stringify(afterSecond?.config)}, :${secondPort} saw ${hits.get(secondPort) ?? 0} requests`,
  );
  check(
    toSecond.resolved && afterSecond?.status === "connected" && (hits.get(secondPort) ?? 0) > 0,
    "reconnectMcpServer reads the config again and connects to the file's new URL",
  );
  finish();
  session.close?.();
  for (const server of listening.splice(0)) await shut(server);

  console.log("\nthe host reconnects on its own");
  const latePort = await freePort();
  let missingHits = 0;
  const missing = createServer((_req, res) => {
    missingHits++;
    res.writeHead(404).end("no");
  });
  listening.push(missing);
  await new Promise<void>((resolve) => missing.listen(0, "127.0.0.1", () => resolve()));
  const missingPort = (missing.address() as any).port as number;
  writeMcpJson({ late: `http://127.0.0.1:${latePort}/mcp`, missing: `http://127.0.0.1:${missingPort}/mcp` });

  const readings: { at: number; servers: any[] }[] = [];
  let resultAt = 0;
  const hosted = new HostedSession(
    { cwd: scratch, prompt: "Reply with only the word ok.", model: "haiku", settingSources: ["project", "local"] },
    (event: Event) => {
      if (event.type === "session.mcp") readings.push({ at: Date.now(), servers: event.servers });
      if (event.type === "session.result") resultAt ||= Date.now();
    },
  );
  hosted.start();
  const turnDeadline = Date.now() + 120_000;
  while (!resultAt && Date.now() < turnDeadline) await sleep(250);
  check(resultAt > 0, "the hosted session finished its turn");
  await sleep(2_000);
  const status = (name: string) => hosted.mcpServers?.find((server) => server.name === name);
  console.log(`  after the turn: ${JSON.stringify(hosted.mcpServers)}`);
  check(status("late")?.status === "failed", "late reads failed");
  check(status("missing")?.status === "failed", "missing (answers 404) reads failed");

  const quietSince = hosted.lastActivityAt;
  const missingHitsBefore = missingHits;
  const downReconnect = await outcome(() => hosted.reconnectMcp("late"));
  console.log(`  a reconnect while late is down: ${JSON.stringify(downReconnect)}`);
  check(!downReconnect.resolved && hosted.lastActivityAt === quietSince, "a reconnect that fails throws and leaves lastActivityAt alone");
  const late = mcpServer(latePort);
  listening.push(late);
  const startedListening = Date.now();
  await listenOn(late, latePort);
  const waitUntil = Date.now() + 90_000;
  while (status("late")?.status !== "connected" && Date.now() < waitUntil) await sleep(250);
  const tookMs = Date.now() - startedListening;
  console.log(`  late read connected ${tookMs}ms after its server started listening; now ${JSON.stringify(hosted.mcpServers)}`);
  check(status("late")?.status === "connected", "the host reconnects late on its own once it listens");
  check(status("missing")?.status === "failed", "missing stays failed");
  check(hosted.lastActivityAt === quietSince, "the retries and the reconnect left lastActivityAt alone");
  console.log(`  missing's error: ${status("missing")?.error}`);
  check(missingHits === missingHitsBefore, `the 404 server was never reconnected (saw ${missingHits - missingHitsBefore} requests after the turn)`);
  hosted.stop();
} finally {
  for (const server of listening) await shut(server);
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length ? `\nmcp-reconnect-config: ${failures.length} check(s) failed` : "\nmcp-reconnect-config: all checks passed");
process.exit(failures.length ? 1 : 0);
