/** What `readLines` needs of a socket, so a test can hand it something that only emits. */
export interface LineSource {
  on(event: "data", listener: (chunk: Buffer) => void): unknown;
  destroy(): void;
}

export interface LineOptions {
  /** The longest unfinished line held, asked after each chunk; past it the socket is dropped. */
  cap(): number;
  /**
   * Asked of each line before the first it admits, which is then read as
   * usual. False drops the socket. Until then a line may be no longer than
   * `ADMISSION_CAP`. Absent, every line is admitted.
   */
  admit?(line: string): boolean;
  line(line: string): void;
  /** Said once, before a drop for a line past `cap`. */
  overflow?(cap: number): void;
}

export const ADMISSION_CAP = 65_536;

/** Newline-framed lines off a socket, trimmed, with blank ones skipped. */
export function readLines(socket: LineSource, options: LineOptions): void {
  let admitted = !options.admit;
  // Held as the chunks that came, not one growing string: re-scanning that for a
  // newline made a 64 MB line freeze every session on the host for seconds.
  let pending: Buffer[] = [];
  let pendingBytes = 0;
  socket.on("data", (chunk: Buffer) => {
    if (!admitted && pendingBytes + chunk.length > ADMISSION_CAP) {
      socket.destroy();
      return;
    }
    let start = 0;
    let newline = chunk.indexOf(10);
    while (newline !== -1) {
      const piece = chunk.subarray(start, newline);
      const line = (pending.length ? Buffer.concat([...pending, piece]) : piece).toString("utf8").trim();
      pending = [];
      pendingBytes = 0;
      start = newline + 1;
      if (line.length > 0 && !admitted) {
        if (options.admit && !options.admit(line)) {
          socket.destroy();
          return;
        }
        admitted = true;
      }
      if (line.length > 0) options.line(line);
      newline = chunk.indexOf(10, start);
    }
    if (start < chunk.length) {
      pending.push(chunk.subarray(start));
      pendingBytes += chunk.length - start;
    }
    const cap = options.cap();
    if (pendingBytes > cap) {
      options.overflow?.(cap);
      socket.destroy();
    }
  });
}
