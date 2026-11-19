// Small, safe file readers shared by the watchers: head, tail, and "bytes appended since offset".

import fs from "node:fs";

export function readRange(file: string, start: number, end: number): string {
  const len = Math.max(0, end - start);
  if (!len) return "";
  const fd = fs.openSync(file, "r");
  try {
    const buf = Buffer.alloc(len);
    const n = fs.readSync(fd, buf, 0, len, start);
    return buf.subarray(0, n).toString("utf8");
  } finally { fs.closeSync(fd); }
}

export const head = (file: string, size: number, bytes: number) => readRange(file, 0, Math.min(size, bytes));

/** The last `bytes` of a file, starting at a line boundary. */
export function tail(file: string, size: number, bytes: number): string {
  const start = Math.max(0, size - bytes);
  const text = readRange(file, start, size);
  if (start === 0) return text;
  const nl = text.indexOf("\n");
  return nl >= 0 ? text.slice(nl + 1) : "";
}

/** Complete lines appended after `offset`; returns the new offset (end of the last complete line). */
export function appended(file: string, offset: number, size: number): { text: string; next: number } {
  if (size <= offset) return { text: "", next: size < offset ? 0 : offset };
  const text = readRange(file, offset, size);
  const last = text.lastIndexOf("\n");
  if (last < 0) return { text: "", next: offset };
  return { text: text.slice(0, last + 1), next: offset + Buffer.byteLength(text.slice(0, last + 1)) };
}

export function safeStat(p: string): fs.Stats | null {
  try { return fs.statSync(p); } catch { return null; }
}

export function safeReaddir(p: string): string[] {
  try { return fs.readdirSync(p); } catch { return []; }
}
