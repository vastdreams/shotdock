// The code panel's file access, scoped to one chat's folder: what changed (git), the original and current text of a
// file, a file list for quick open, and save. Every path is resolved and must stay inside the folder.

import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";

export interface Change { path: string; status: "modified" | "added" | "deleted" | "untracked" | "renamed" }

const MAX_FILE = 4_000_000;
const BINARY = /\.(pdf|png|jpe?g|gif|webp|ico|icns|bmp|tiff?|heic|mp[34]|mov|wav|m4a|zip|gz|tgz|bz2|xz|7z|rar|dmg|pkg|exe|dll|so|dylib|bin|class|jar|wasm|docx?|xlsx?|pptx?|key|numbers|pages|sqlite3?|db|woff2?|ttf|otf|psd|ai|sketch|fig)$/i;
export const isBinaryName = (p: string) => BINARY.test(p);
const SKIP = new Set(["node_modules", ".git", "dist", "build", "release", ".next", ".venv", "venv", "__pycache__", ".cache", "target"]);

function git(folder: string, args: string[]): Promise<string | null> {
  return new Promise((resolve) => execFile("git", ["-C", folder, ...args], { maxBuffer: 20_000_000, timeout: 8000 },
    (err, out) => resolve(err ? null : out)));
}

/** Resolve `rel` inside `folder`, or throw. Follows symlinks so a link cannot escape the folder. */
export function inside(folder: string, rel: string): string {
  const root = fs.realpathSync(folder);
  const target = path.resolve(root, rel);
  // Resolve the deepest part that exists (so symlinks are followed), then add the parts that don't exist yet.
  let head = target, tail = "";
  while (!fs.existsSync(head) && path.dirname(head) !== head) { tail = path.join(path.basename(head), tail); head = path.dirname(head); }
  const real = path.join(fs.realpathSync(head), tail);
  if (real !== root && !real.startsWith(root + path.sep)) throw new Error("That file is outside the chat's folder.");
  return real;
}

export async function repoRoot(folder: string): Promise<string | null> {
  const out = await git(folder, ["rev-parse", "--show-toplevel"]);
  return out ? out.trim() : null;
}

/** Files changed in the folder's git work tree (staged or not, plus new files), paths relative to the folder. */
export async function changes(folder: string): Promise<{ git: boolean; items: Change[] }> {
  const out = await git(folder, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."]);
  if (out === null) return { git: false, items: [] };
  const root = (await repoRoot(folder)) ?? folder;
  const base = fs.realpathSync(folder);        // git reports real paths (/private/var, not /var)
  const items: Change[] = [];
  const parts = out.split("\0");
  for (let i = 0; i < parts.length; i++) {
    const e = parts[i];
    if (e.length < 4) continue;
    const xy = e.slice(0, 2), file = e.slice(3);
    if (xy[0] === "R" || xy[0] === "C") i++; // the original name follows
    const status: Change["status"] = xy === "??" ? "untracked" : xy.includes("D") ? "deleted" : xy.includes("A") ? "added" : xy[0] === "R" ? "renamed" : "modified";
    const rel = path.relative(base, path.join(root, file));
    if (!rel.startsWith("..")) items.push({ path: rel, status });
  }
  return { git: true, items: items.slice(0, 500) };
}

/** Current text and, when the folder is a git repo, the committed text (HEAD) for a diff. */
export async function readFile(folder: string, rel: string): Promise<{ current: string | null; original: string | null; binary: boolean }> {
  const abs = inside(folder, rel);
  if (isBinaryName(abs)) return { current: null, original: null, binary: true };
  let current: string | null = null, binary = false;
  if (fs.existsSync(abs)) {
    const st = fs.statSync(abs);
    if (st.size > MAX_FILE) throw new Error("File is too large to open here.");
    const buf = fs.readFileSync(abs);
    binary = buf.subarray(0, 8000).includes(0);
    current = binary ? null : buf.toString("utf8");
  }
  const root = await repoRoot(folder);
  let original: string | null = null;
  if (root && !binary) {
    const relToRoot = path.relative(root, abs).split(path.sep).join("/");
    original = await git(folder, ["show", `HEAD:${relToRoot}`]);
  }
  return { current, original, binary };
}

export function writeFile(folder: string, rel: string, content: string): void {
  const abs = inside(folder, rel);
  const tmp = abs + ".shotdock-tmp";
  fs.writeFileSync(tmp, content);
  fs.renameSync(tmp, abs);
}

/** Up to `limit` files for quick open: git's list when available, otherwise a bounded walk. */
export async function listFiles(folder: string, query: string, limit = 200): Promise<string[]> {
  const q = query.toLowerCase();
  let files: string[] = [];
  const out = await git(folder, ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "."]);
  if (out !== null) files = out.split("\0").filter(Boolean);
  else {
    const walk = (dir: string, depth: number) => {
      if (depth > 6 || files.length > 20000) return;
      for (const n of fs.readdirSync(dir, { withFileTypes: true })) {
        if (n.name.startsWith(".") && n.name !== ".github") continue;
        if (SKIP.has(n.name)) continue;
        const p = path.join(dir, n.name);
        if (n.isSymbolicLink()) continue;          // don't follow links out of the folder (or into loops)
        if (n.isDirectory()) walk(p, depth + 1); else files.push(path.relative(folder, p));
      }
    };
    try { walk(folder, 0); } catch { /* unreadable */ }
  }
  const hit = q ? files.filter((f) => f.toLowerCase().includes(q)) : files;
  return hit.sort((a, b) => a.length - b.length).slice(0, limit);
}
