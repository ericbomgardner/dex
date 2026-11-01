/**
 * A file too large for the request is taken out of it without a word, and
 * only the request record says so. Readings:
 *
 *   - Read hands back a ~19MB PDF whole, as a document block in the result.
 *   - The user record keeps that document.
 *   - The `api-request-blob` written for the request has the same tool_result
 *     with `[media removed: request limit]` where the document was.
 *   - With the host's brief, the model says it never saw the file.
 *
 * Read only sends a whole PDF on models that take one, so this runs on opus.
 *
 *   node test/media-dropped-probe.ts
 */

import { randomBytes } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { HostedSession } from "../src/session.ts";
import type { Event } from "../src/protocol.ts";

const PLACEHOLDER = "[media removed: request limit]";
const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const dir = realpathSync(mkdtempSync(path.join(tmpdir(), "media-dropped-probe-")));
const pdfPath = path.join(dir, "big.pdf");

/**
 * One page holding an uncompressed image of noise, 19.97MB: under Read's 20MiB
 * cutoff, and over the 24MiB of documents a request holds once base64'd. At
 * 17.9MB it was sent whole.
 */
function writeNoisePDF(file: string): void {
  const side = 2580;
  const pixels = randomBytes(side * side * 3);
  const content = Buffer.from("q 540 0 0 540 36 200 cm /Im0 Do Q\n");
  const parts: Buffer[] = [];
  const offsets: number[] = [];
  let length = 0;
  const push = (chunk: Buffer | string) => {
    const buffer = typeof chunk === "string" ? Buffer.from(chunk, "latin1") : chunk;
    parts.push(buffer);
    length += buffer.length;
  };
  const object = (id: number, body: (Buffer | string)[]) => {
    offsets[id] = length;
    push(`${id} 0 obj\n`);
    for (const piece of body) push(piece);
    push("\nendobj\n");
  };
  push("%PDF-1.4\n");
  object(1, ["<< /Type /Catalog /Pages 2 0 R >>"]);
  object(2, ["<< /Type /Pages /Kids [3 0 R] /Count 1 >>"]);
  object(3, ["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>"]);
  object(4, [
    `<< /Type /XObject /Subtype /Image /Width ${side} /Height ${side} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length ${pixels.length} >>\nstream\n`,
    pixels,
    "\nendstream",
  ]);
  object(5, [`<< /Length ${content.length} >>\nstream\n`, content, "\nendstream"]);
  const xref = length;
  push(`xref\n0 6\n0000000000 65535 f \n`);
  for (let id = 1; id <= 5; id++) push(`${String(offsets[id]).padStart(10, "0")} 00000 n \n`);
  push(`trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);
  writeFileSync(file, Buffer.concat(parts));
}

function records(sessionId: string): any[] {
  const file = path.join(homedir(), ".claude/projects", dir.replace(/[^a-zA-Z0-9]/g, "-"), `${sessionId}.jsonl`);
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8").trim().split("\n").map((line) => JSON.parse(line));
}

const resultBlocks = (record: any, toolUseId: string): any[] =>
  (Array.isArray(record.message?.content) ? record.message.content : []).filter((block: any) => block?.type === "tool_result" && block.tool_use_id === toolUseId)
    .flatMap((block: any) => (Array.isArray(block.content) ? block.content : []));

const deadline = (ms: number) =>
  new Promise<never>((_, reject) => setTimeout(() => reject(new Error(`nothing within ${ms / 1000}s`)), ms));

writeNoisePDF(pdfPath);
let resolveTurn: () => void = () => {};
const turn = new Promise<void>((resolve) => (resolveTurn = resolve));
const session = new HostedSession(
  {
    cwd: dir,
    prompt: `Read ${pdfPath} with the Read tool, without the pages parameter, and describe the image on its page.`,
    model: "opus",
    permissionMode: "auto",
    settingSources: [],
  },
  (event: Event) => {
    if (event.type === "session.result") resolveTurn();
  },
  async () => "unused",
);

try {
  session.start();
  await Promise.race([turn, deadline(300_000)]);
  await new Promise((resolve) => setTimeout(resolve, 1_000));
  const all = records(session.sessionId ?? "");
  const call = all
    .filter((record) => record.type === "assistant")
    .flatMap((record) => record.message?.content ?? [])
    .find((block: any) => block?.type === "tool_use" && block.name === "Read" && !block.input?.pages);
  check(call, "the session read the PDF whole");
  const id = call?.id ?? "";
  const turnRecord = all.find((record) => record.type === "user" && resultBlocks(record, id).length > 0);
  check(resultBlocks(turnRecord ?? {}, id).some((block) => block.type === "document"), "the user record keeps the document");
  const blob = all.find((record) => record.type === "api-request-blob" && resultBlocks(record, id).length > 0);
  check(blob, "a request record repeats that result");
  check(
    resultBlocks(blob ?? {}, id).some((block) => block.type === "text" && block.text === PLACEHOLDER) &&
      !resultBlocks(blob ?? {}, id).some((block) => block.type === "document"),
    `and has ${PLACEHOLDER} where the document was`,
  );
  const reply = all
    .filter((record) => record.type === "assistant")
    .flatMap((record) => record.message?.content ?? [])
    .filter((block: any) => block?.type === "text")
    .map((block: any) => String(block.text))
    .join("\n");
  check(
    blob && /removed|too large|request limit/i.test(reply),
    `the model says the file was dropped (${JSON.stringify(reply.slice(0, 160))})`,
  );
  session.stop();
} catch (error: any) {
  check(false, `probe ran: ${error?.message ?? error}`);
} finally {
  await new Promise((resolve) => setTimeout(resolve, 1_000));
  rmSync(dir, { recursive: true, force: true });
  rmSync(path.join(homedir(), ".claude/projects", dir.replace(/[^a-zA-Z0-9]/g, "-")), { recursive: true, force: true });
}

if (failures.length > 0) {
  console.log(`\n${failures.length} failed`);
  process.exit(1);
}
console.log("\nall ok");
process.exit(0);
