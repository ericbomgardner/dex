import { randomUUID, type UUID } from "node:crypto";
import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";

/**
 * The session's input, held open for its whole life.
 *
 * It must never finish on its own: the SDK closes the input stream after the
 * last message, and a closed stream takes the permission callback with it, so
 * a stream that ends when the first prompt is consumed is a session that can
 * never ask you anything.
 */
export class PushStream {
  #queue: SDKUserMessage[] = [];
  #waiting: ((value: IteratorResult<SDKUserMessage, undefined>) => void) | null = null;
  #closed = false;

  push(text: string, uuid: UUID = randomUUID(), priority?: "now"): void {
    const message: SDKUserMessage = {
      type: "user",
      uuid,
      message: { role: "user", content: text },
      parent_tool_use_id: null,
      ...(priority ? { priority } : {}),
    };
    if (this.#waiting) {
      const resolve = this.#waiting;
      this.#waiting = null;
      resolve({ value: message, done: false });
      return;
    }
    this.#queue.push(message);
  }

  close(): void {
    this.#closed = true;
    if (this.#waiting) {
      const resolve = this.#waiting;
      this.#waiting = null;
      resolve({ value: undefined, done: true });
    }
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<SDKUserMessage> {
    while (true) {
      const queued = this.#queue.shift();
      if (queued) {
        yield queued;
        continue;
      }
      if (this.#closed) return;
      const next = await new Promise<IteratorResult<SDKUserMessage, undefined>>((resolve) => {
        this.#waiting = resolve;
      });
      if (next.done) return;
      yield next.value;
    }
  }
}
