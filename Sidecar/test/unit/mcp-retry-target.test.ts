import assert from "node:assert/strict";
import { test } from "node:test";

import type { McpServerStatus } from "@anthropic-ai/claude-agent-sdk";

import { mcpRetryTarget } from "../../src/mcp.ts";

const REFUSED = "ECONNREFUSED: Unable to connect. Is the computer able to access the url?";

function failed(url: string, error = REFUSED): McpServerStatus {
  return { name: "s", status: "failed", error, config: { type: "http", url } };
}

test("a refused http server is knocked on at its host and port", () => {
  assert.deepEqual(mcpRetryTarget(failed("http://localhost:7123/mcp")), { host: "localhost", port: 7123 });
});

test("a URL without a port takes its scheme's", () => {
  assert.equal(mcpRetryTarget(failed("https://example.com/mcp"))?.port, 443);
  assert.equal(mcpRetryTarget(failed("http://example.com/mcp"))?.port, 80);
});

test("an IPv6 host loses its brackets", () => {
  assert.deepEqual(mcpRetryTarget(failed("http://[::1]:8080/mcp")), { host: "::1", port: 8080 });
});

test("sse is retried like http", () => {
  const server: McpServerStatus = { ...failed("x"), config: { type: "sse", url: "http://localhost:7123/sse" } };
  assert.deepEqual(mcpRetryTarget(server), { host: "localhost", port: 7123 });
});

test("every connection-level failure counts", () => {
  for (const code of ["ECONNRESET", "ETIMEDOUT", "EHOSTUNREACH", "ENETUNREACH", "ENOTFOUND", "EADDRNOTAVAIL"]) {
    assert.notEqual(mcpRetryTarget(failed("http://localhost:1/", `${code}: gone`)), null, code);
  }
});

test("a server that answered is left alone", () => {
  assert.equal(mcpRetryTarget(failed("http://localhost:7123/mcp", "HTTP 404: Not Found")), null);
  assert.equal(
    mcpRetryTarget(failed("http://localhost:7123/mcp", "Error POSTing to endpoint: ECONNREFUSED from the database")),
    null,
  );
});

test("only a failed server, with an error, over http or sse", () => {
  assert.equal(mcpRetryTarget({ ...failed("http://localhost:7123/mcp"), status: "needs-auth" }), null);
  assert.equal(mcpRetryTarget({ ...failed("http://localhost:7123/mcp"), status: "connected" }), null);
  assert.equal(mcpRetryTarget({ ...failed("http://localhost:7123/mcp"), error: undefined }), null);
  assert.equal(mcpRetryTarget({ ...failed("x"), config: { type: "stdio", command: "x" } }), null);
  assert.equal(mcpRetryTarget({ name: "s", status: "failed", error: REFUSED }), null);
});

test("a URL that doesn't parse is not retried", () => {
  assert.equal(mcpRetryTarget(failed("not a url")), null);
});
