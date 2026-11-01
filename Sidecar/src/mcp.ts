import { connect } from "node:net";
import type { McpServerStatus } from "@anthropic-ai/claude-agent-sdk";

import { DEX_SERVER } from "./dex-server.ts";
import type { McpServerReading } from "./protocol.ts";

const MCP_RETRY_FIRST_MS = 5_000;
const MCP_RETRY_LONGEST_MS = 60_000;
const MCP_KNOCK_TIMEOUT_MS = 2_000;
const MCP_RECONFIG_MS = 5 * 60_000;

interface McpRetryTarget {
  host: string;
  port: number;
}

interface McpRetry {
  target: McpRetryTarget;
  delay: number;
  timer: ReturnType<typeof setTimeout> | null;
  checking: boolean;
  reconnectedAt: number;
}

/**
 * The CLI never retries a server that failed to connect, so the host knocks
 * on its port with a backoff and reconnects once something answers. The
 * backoff carries across reconnects that fail anyway, so a port that takes
 * the knock but not the CLI's request is asked less and less often. The port
 * is the one the session started with until a reconnect re-reads the config,
 * so every few minutes it reconnects without waiting for the knock.
 */
export class McpRetries {
  readonly #retries = new Map<string, McpRetry>();
  readonly #reconnect: (server: string) => Promise<void>;
  readonly #report: () => Promise<void>;
  #stopped = false;

  constructor(reconnect: (server: string) => Promise<void>, report: () => Promise<void>) {
    this.#reconnect = reconnect;
    this.#report = report;
  }

  update(raw: McpServerStatus[]): void {
    if (this.#stopped) return;
    const targets = new Map<string, McpRetryTarget>();
    for (const server of raw) {
      const target = mcpRetryTarget(server);
      if (target && server.name !== DEX_SERVER) targets.set(server.name, target);
    }
    for (const [name, retry] of this.#retries) {
      if (targets.has(name)) continue;
      if (retry.timer) clearTimeout(retry.timer);
      this.#retries.delete(name);
    }
    for (const [name, target] of targets) {
      const retry = this.#retries.get(name) ?? {
        target,
        delay: MCP_RETRY_FIRST_MS,
        timer: null,
        checking: false,
        reconnectedAt: Date.now(),
      };
      retry.target = target;
      this.#retries.set(name, retry);
      if (!retry.timer && !retry.checking) this.#knockLater(name, retry);
    }
  }

  stop(): void {
    this.#stopped = true;
    for (const retry of this.#retries.values()) if (retry.timer) clearTimeout(retry.timer);
    this.#retries.clear();
  }

  #knockLater(name: string, retry: McpRetry): void {
    retry.timer = setTimeout(() => void this.#knock(name, retry), retry.delay);
    retry.timer.unref?.();
  }

  async #knock(name: string, retry: McpRetry): Promise<void> {
    retry.timer = null;
    retry.checking = true;
    const listening = await portListening(retry.target);
    retry.delay = Math.min(retry.delay * 2, MCP_RETRY_LONGEST_MS);
    if (this.#stopped || this.#retries.get(name) !== retry) return;
    const reconnect = listening || Date.now() - retry.reconnectedAt >= MCP_RECONFIG_MS;
    if (reconnect) {
      retry.reconnectedAt = Date.now();
      try {
        await this.#reconnect(name);
      } catch {
        // Still down as far as the CLI can tell; the reading below says so.
      }
    }
    retry.checking = false;
    if (reconnect) await this.#report();
    else if (!this.#stopped && this.#retries.get(name) === retry) this.#knockLater(name, retry);
  }
}

/** Connection-level failures only: a server that answered, even with a 401 or 404, is left alone. */
const MCP_UNREACHABLE = /^(ECONNREFUSED|ECONNRESET|ETIMEDOUT|EHOSTUNREACH|ENETUNREACH|ENOTFOUND|EADDRNOTAVAIL)\b/;

/** Where to knock for a server from `mcpServerStatus()` worth retrying, or null. */
export function mcpRetryTarget(server: McpServerStatus): McpRetryTarget | null {
  if (server?.status !== "failed") return null;
  const config = server.config;
  if (config?.type !== "http" && config?.type !== "sse") return null;
  if (typeof server.error !== "string" || !MCP_UNREACHABLE.test(server.error)) return null;
  try {
    const url = new URL(config.url);
    const port = Number(url.port) || (url.protocol === "https:" ? 443 : 80);
    return { host: url.hostname.replace(/^\[(.*)\]$/, "$1"), port };
  } catch {
    return null;
  }
}

function portListening(target: McpRetryTarget): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect({ host: target.host, port: target.port, timeout: MCP_KNOCK_TIMEOUT_MS });
    const settle = (listening: boolean) => {
      socket.destroy();
      resolve(listening);
    };
    socket.once("connect", () => settle(true));
    socket.once("timeout", () => settle(false));
    socket.once("error", () => settle(false));
  });
}

/** Name, status and error only: the rest carries config, which can hold tokens. */
export function mcpReadings(servers: unknown): McpServerReading[] | null {
  if (!Array.isArray(servers)) return null;
  return servers
    .filter((server) => typeof server?.name === "string" && typeof server?.status === "string")
    .filter((server) => server.name !== DEX_SERVER)
    .map((server) => ({
      name: server.name,
      status: server.status,
      ...(typeof server.error === "string" ? { error: server.error } : {}),
    }));
}
