/**
 * What a session says when an MCP server goes away after startup.
 *
 *   node test/mcp-drop-probe.ts
 *
 * A row marks a server the session can't use. The startup status is one half
 * of that (mcp-status-probe); this is the other. It checks that the status
 * does not move when a server dies, so the transcript is the only place a drop
 * shows, and that each way a call can fail to reach its server comes back with
 * the text `McpCallOutcome.isConnectionFailure` reads, while a tool's own
 * error does not.
 *
 * Servers: `local`, a stdio script killed between turns; `gone`, an http
 * server closed between turns; `web`, an http server that stays up and fails
 * in a different way per tool.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-mcp-drop-"));
const script = path.join(scratch, "server.mjs");
const pidFile = path.join(scratch, "pid");
const tool = (name: string) => ({ name, description: "Probe tool", inputSchema: { type: "object", properties: {} } });
const tools = ["ping", "crash", "hang", "refuse", "boom"].map(tool);

writeFileSync(
  script,
  `
import { createInterface } from "node:readline";
import { writeFileSync } from "node:fs";
writeFileSync(${JSON.stringify(pidFile)}, String(process.pid));
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
createInterface({ input: process.stdin }).on("line", (line) => {
  const m = JSON.parse(line);
  if (m.id === undefined) return;
  if (m.method === "initialize") reply(m.id, { protocolVersion: m.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "p", version: "0" } });
  else if (m.method === "tools/list") reply(m.id, { tools: ${JSON.stringify(tools)} });
  else if (m.method === "tools/call") {
    const name = m.params.name;
    if (name === "crash") process.exit(3);
    if (name === "hang") return;
    if (name === "refuse") return reply(m.id, { isError: true, content: [{ type: "text", text: "No such issue: ABC-1" }] });
    if (name === "boom") return process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, error: { code: -32603, message: "internal kaboom" } }) + "\\n");
    reply(m.id, { content: [{ type: "text", text: "pong" }] });
  } else process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, error: { code: -32601, message: "no" } }) + "\\n");
});
`,
);

function httpServer(failing: boolean) {
  return createServer((req, res) => {
    if (req.method !== "POST") return void res.writeHead(405).end();
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const m = JSON.parse(body);
      if (m.id === undefined) return void res.writeHead(202).end();
      if (failing && m.method === "tools/call") {
        const name = m.params.name;
        if (name === "crash") return void req.socket.destroy();
        if (name === "hang") return;
        if (name === "refuse") return void res.writeHead(401, { "www-authenticate": "Bearer" }).end("unauthorized");
        if (name === "boom") return void res.writeHead(500).end("oops");
      }
      const result =
        m.method === "initialize"
          ? { protocolVersion: m.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "h", version: "0" } }
          : m.method === "tools/list"
            ? { tools: failing ? tools : [tool("ping")] }
            : { content: [{ type: "text", text: "pong" }] };
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id: m.id, result }));
    });
  });
}
const listen = async (server: ReturnType<typeof createServer>) => {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  return (server.address() as any).port as number;
};
const gone = httpServer(false);
const web = httpServer(true);
const gonePort = await listen(gone);
const webPort = await listen(web);

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

/** The rule the app applies, `McpCallOutcome.isConnectionFailure`, restated. */
function readsAsUnreachable(text: string): boolean {
  if (text === "Connection closed" || text.startsWith("Error POSTing to endpoint: ")) return true;
  if (text.startsWith('MCP server "') && (text.includes('" timed out after ') || text.endsWith('" session expired'))) return true;
  if (!/^E[A-Z]{3,}: /.test(text)) return false;
  return text.includes("Unable to connect. Is the computer able to access the url?") || text.endsWith("pass `verbose: true` in the second argument to fetch()");
}

const failing = tools.filter((t) => t.name !== "ping").map((t) => t.name);
const allowed = [
  "mcp__local__ping", "mcp__gone__ping",
  ...failing.flatMap((name) => [`mcp__local__${name}`, `mcp__web__${name}`]),
];

try {
  let send: (text: string) => void = () => {};
  let finish = () => {};
  const done = new Promise<void>((resolve) => (finish = resolve));
  async function* input() {
    const queue = ["Call mcp__local__ping and mcp__gone__ping once each, then say ok."];
    let wake = () => {};
    send = (text) => {
      queue.push(text);
      wake();
    };
    while (true) {
      while (queue.length) yield { type: "user", message: { role: "user", content: queue.shift()! }, parent_tool_use_id: null, session_id: "" };
      const next = new Promise<void>((resolve) => (wake = resolve));
      if (await Promise.race([next.then(() => false), done.then(() => true)])) return;
    }
  }
  const session = query({
    prompt: input() as any,
    options: {
      cwd: scratch,
      model: "haiku",
      allowedTools: allowed,
      env: { ...process.env, MCP_TOOL_TIMEOUT: "4000" },
      mcpServers: {
        local: { command: process.execPath, args: [script] },
        gone: { type: "http", url: `http://127.0.0.1:${gonePort}/mcp` },
        web: { type: "http", url: `http://127.0.0.1:${webPort}/mcp` },
      },
    } as any,
  });
  const statuses = async () =>
    Object.fromEntries((await session.mcpServerStatus()).map((server: any) => [server.name, server.status]));

  const names: Record<string, string> = {};
  const results: Record<string, { isError: boolean; text: string }> = {};
  let turns = 0;
  let firstPid = "";
  let idle: Record<string, string> = {};
  for await (const message of session) {
    for (const block of (message as any).message?.content ?? []) {
      if (block.type === "tool_use") names[block.id] = block.name;
      if (block.type === "tool_result" && names[block.tool_use_id]?.startsWith("mcp__")) {
        const text = typeof block.content === "string" ? block.content : (block.content ?? []).map((part: any) => part.text ?? "").join("");
        results[names[block.tool_use_id]] = { isError: block.is_error === true, text };
      }
    }
    if (message.type !== "result") continue;
    turns += 1;
    if (turns === 1) {
      console.log(`  after turn 1: ${JSON.stringify(await statuses())}`);
      firstPid = readFileSync(pidFile, "utf8");
      process.kill(Number(firstPid), "SIGKILL");
      gone.close();
      gone.closeAllConnections();
      await new Promise((resolve) => setTimeout(resolve, 10_000));
      idle = await statuses();
      console.log(`  10s after both died: ${JSON.stringify(idle)}`);
      send(`Call each of these tools exactly once, one at a time, in this order, and don't retry any: mcp__local__ping, mcp__gone__ping, ${failing.flatMap((name) => [`mcp__local__${name}`, `mcp__web__${name}`]).join(", ")}. Then say done.`);
    } else {
      console.log(`  after turn 2: ${JSON.stringify(await statuses())}`);
      break;
    }
  }
  finish();
  session.close?.();

  for (const [name, result] of Object.entries(results)) console.log(`  ${name}: ${result.isError ? "error" : "ok"} ${JSON.stringify(result.text.slice(0, 120))}`);

  check(idle.local === "connected" && idle.gone === "connected", "a stdio server killed and an http server closed while idle both still read connected");
  check(readFileSync(pidFile, "utf8") !== firstPid && results["mcp__local__ping"]?.isError === false, "the next call to a killed stdio server starts it again and is answered");
  check(results["mcp__gone__ping"]?.isError && readsAsUnreachable(results["mcp__gone__ping"].text), "a call to a closed http server errors with text read as unreachable");
  for (const server of ["local", "web"]) {
    for (const name of ["crash", "hang"]) {
      const result = results[`mcp__${server}__${name}`];
      check(result?.isError && readsAsUnreachable(result.text), `${server} ${name}: errors with text read as unreachable`);
    }
    const refused = results[`mcp__${server}__refuse`];
    const boom = results[`mcp__${server}__boom`];
    if (server === "local") {
      check(refused?.isError && !readsAsUnreachable(refused.text), "a stdio tool's own isError result is not read as unreachable");
      check(boom?.isError && !readsAsUnreachable(boom.text), "a stdio JSON-RPC error is not read as unreachable");
    } else {
      check(refused?.isError && readsAsUnreachable(refused.text), "an http 401 mid-session errors with text read as unreachable");
      check(boom?.isError && readsAsUnreachable(boom.text), "an http 500 errors with text read as unreachable");
    }
  }
} finally {
  web.close();
  web.closeAllConnections();
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length ? `\nmcp-drop: ${failures.length} check(s) failed` : "\nmcp-drop: all checks passed");
process.exit(failures.length ? 1 : 0);
