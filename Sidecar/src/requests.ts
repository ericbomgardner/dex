import { z } from "zod";

import { why } from "./log.ts";
import type { Request } from "./protocol.ts";

/**
 * Every request's shape, checked as a line comes off the socket so `handle`
 * only ever sees the fields its type promises. Unknown keys are let through
 * and dropped: an app newer than the host may send a field this one doesn't
 * read yet.
 */
type RequestOf<T extends Request["type"]> = Extract<Request, { type: T }>;

const id = z.string();
const text = z.string();
const optional = z.string().optional();

const origin = z.object({ watcher: optional, reason: optional, parent: optional });

const schemas: { [T in Request["type"]]: z.ZodType<RequestOf<T>> } = {
  hello: z.object({
    id,
    type: z.literal("hello"),
    protocol: z.number(),
    launches: z.boolean().optional(),
  }),
  launched: z.object({ id, type: z.literal("launched"), launchId: text, key: optional, error: optional }),
  start: z.object({
    id,
    type: z.literal("start"),
    cwd: text,
    prompt: text,
    model: optional,
    permissionMode: optional,
    name: optional,
    origin: origin.optional(),
    settingSources: z.array(z.enum(["user", "project", "local"])).optional(),
    outputStyle: optional,
    effort: optional,
    resume: optional,
    key: optional,
    apiKey: optional,
  }),
  send: z.object({ id, type: z.literal("send"), key: text, text }),
  answer: z.discriminatedUnion("kind", [
    z.object({
      id,
      type: z.literal("answer"),
      askId: text,
      kind: z.literal("question"),
      answers: z.record(z.string(), z.union([z.string(), z.array(z.string())])),
      annotations: z.record(z.string(), z.object({ notes: optional })).optional(),
      response: optional,
    }),
    z.object({
      id,
      type: z.literal("answer"),
      askId: text,
      kind: z.literal("permission"),
      optionId: text,
      message: optional,
    }),
  ]),
  mode: z.object({ id, type: z.literal("mode"), key: text, permissionMode: text }),
  effort: z.object({ id, type: z.literal("effort"), key: text, effort: text }),
  defaults: z.object({ id, type: z.literal("defaults"), cwd: text }),
  interrupt: z.object({ id, type: z.literal("interrupt"), key: text }),
  stop: z.object({ id, type: z.literal("stop"), key: text }),
  stopTask: z.object({ id, type: z.literal("stopTask"), key: text, taskId: text }),
  mcpReconnect: z.object({ id, type: z.literal("mcpReconnect"), key: text, server: text }),
  mcpLogin: z.object({ id, type: z.literal("mcpLogin"), key: text, server: text }),
  rename: z.object({ id, type: z.literal("rename"), sessionId: text, title: text }),
  side: z.object({
    id,
    type: z.literal("side"),
    key: text,
    question: text,
    history: z.array(z.object({ question: text, response: text })).optional(),
  }),
};

export type ParsedRequest =
  | { ok: true; request: Request }
  /** `id` is the request's own where it had one, `"?"` where it didn't. */
  | { ok: false; id: string; error: string };

/** One line from a client, as a request `handle` can trust, or the reply to refuse it with. */
export function parseRequest(line: string): ParsedRequest {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch (error) {
    return { ok: false, id: "?", error: `unparseable: ${why(error)}` };
  }
  const fields = typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
  const replyId = typeof fields.id === "string" ? fields.id : "?";
  const type = fields.type;
  // The app reads this exact text as a host too old for the request.
  if (typeof type !== "string" || !Object.hasOwn(schemas, type)) return { ok: false, id: replyId, error: "unknown request" };
  const result = schemas[type as Request["type"]].safeParse(value);
  if (!result.success) {
    const problems = result.error.issues.map((issue) =>
      issue.path.length > 0 ? `${issue.path.join(".")}: ${issue.message}` : issue.message,
    );
    return { ok: false, id: replyId, error: `bad ${type} request: ${problems.join("; ")}` };
  }
  return { ok: true, request: result.data };
}
