// Structured JSON log with redaction built in. One line per event: {at, level, scope, msg, ...fields}.

import fs from "node:fs";
import path from "node:path";

const PATTERNS: RegExp[] = [
  /sk-ant-[A-Za-z0-9_\-]{10,}/g,           // Anthropic keys
  /sk-[A-Za-z0-9]{20,}/g,                   // other provider keys
  /gh[pousr]_[A-Za-z0-9]{20,}/g,            // GitHub tokens
  /glpat-[A-Za-z0-9_\-]{15,}/g,             // GitLab tokens
  /AKIA[0-9A-Z]{16}/g,                      // AWS access key ids
  /eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}/g, // JWTs
  /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/g, // emails
];

export function redact(s: string): string {
  return PATTERNS.reduce((acc, p) => acc.replace(p, "[redacted]"), s);
}

let file: string | null = null;

export function initLog(dir: string): string {
  fs.mkdirSync(dir, { recursive: true });
  file = path.join(dir, "shotdock.log");
  try { if (fs.statSync(file).size > 5_000_000) fs.renameSync(file, file + ".1"); } catch { /* new file */ }
  return file;
}

export function log(level: "info" | "warn" | "error", scope: string, msg: string, fields: Record<string, unknown> = {}): void {
  const line = redact(JSON.stringify({ at: new Date().toISOString(), level, scope, msg, ...fields }));
  if (file) fs.appendFile(file, line + "\n", () => undefined);
  if (process.env.SHOTDOCK_DEBUG) console.log(line);
}
