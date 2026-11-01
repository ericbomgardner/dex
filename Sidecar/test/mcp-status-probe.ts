/**
 * What a session says about its MCP servers, and when.
 *
 *   node test/mcp-status-probe.ts
 *
 * Settings shows each server's status as the sessions report it, so the host
 * reads it twice: off the `init` frame's `mcp_servers`, and from
 * `mcpServerStatus()` after init and after each turn. This checks the fields
 * the host keeps (`name`, `status`, `error`) are where it reads them, that a
 * dead server reads `failed` rather than going missing, and that a working one
 * reads `connected` by the end of the first turn — `init` alone may still say
 * `pending`, which is why the host asks again.
 *
 * The working server is a stdio script written to the scratch directory; the
 * dead one is an http server on a port nothing listens on.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-mcp-status-"));
const script = path.join(scratch, "server.mjs");
writeFileSync(
  script,
  `
import { createInterface } from "node:readline";
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.id === undefined) return;
  if (message.method === "initialize") {
    reply(message.id, { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "probe", version: "0" } });
  } else if (message.method === "tools/list") {
    reply(message.id, { tools: [] });
  } else {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "no" } }) + "\\n");
  }
});
`,
);

/** A port that was free a moment ago, so nothing answers on it. */
const deadPort = await new Promise<number>((resolve) => {
  const server = createServer().listen(0, "127.0.0.1", () => {
    const port = (server.address() as any).port;
    server.close(() => resolve(port));
  });
});

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const byName = (list: any[] | undefined, name: string) => list?.find((server) => server?.name === name);

try {
  // Streamed, as the host does: a string prompt closes the query at the result,
  // and `mcpServerStatus()` asked after that is refused.
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
      mcpServers: {
        alive: { command: process.execPath, args: [script] },
        dead: { type: "http", url: `http://127.0.0.1:${deadPort}/mcp` },
      },
    } as any,
  });

  let initServers: any[] | undefined;
  let afterTurn: any[] | undefined;
  for await (const message of session) {
    if (message.type === "system" && (message as any).subtype === "init" && !initServers) {
      initServers = (message as any).mcp_servers;
    }
    if (message.type === "result") {
      afterTurn = await session.mcpServerStatus();
      break;
    }
  }
  finish();
  session.close?.();

  console.log(`  init: ${JSON.stringify(initServers)}`);
  console.log(`  after the turn: ${JSON.stringify(afterTurn?.map(({ name, status, error }: any) => ({ name, status, error })))}`);

  check(Array.isArray(initServers), "init carries mcp_servers as a list");
  check(
    typeof byName(initServers, "alive")?.status === "string" && typeof byName(initServers, "dead")?.status === "string",
    "init names every configured server, each with a string status",
  );
  check(byName(afterTurn, "alive")?.status === "connected", "a working stdio server reads connected after the first turn");
  check(byName(afterTurn, "dead")?.status === "failed", "a server nothing answers for reads failed, not missing");
  const error = byName(afterTurn, "dead")?.error;
  check(error === undefined || typeof error === "string", "a failed server's error, where given, is a string");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length ? `\nmcp-status: ${failures.length} check(s) failed` : "\nmcp-status: all checks passed");
process.exit(failures.length ? 1 : 0);
