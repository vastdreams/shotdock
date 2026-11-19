import { describe, it, expect } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { inside, changes, readFile, writeFile, listFiles } from "../src/main/adapters/workspace";

const repo = fs.mkdtempSync(path.join(os.tmpdir(), "sd-ws-"));
const g = (...a: string[]) => execFileSync("git", ["-C", repo, ...a], { stdio: "pipe" });
g("init", "-q"); g("config", "user.email", "t@t"); g("config", "user.name", "t");
fs.writeFileSync(path.join(repo, "a.ts"), "export const a = 1;\n");
fs.mkdirSync(path.join(repo, "src"));
fs.writeFileSync(path.join(repo, "src", "b.ts"), "b\n");
g("add", "."); g("commit", "-qm", "init");
fs.writeFileSync(path.join(repo, "a.ts"), "export const a = 2;\n");
fs.writeFileSync(path.join(repo, "new.md"), "# new\n");

describe("workspace (code panel file access)", () => {
  it("refuses paths outside the chat folder, including via symlinks", () => {
    expect(() => inside(repo, "../etc/passwd")).toThrow(/outside/);
    expect(() => inside(repo, "/etc/hosts")).toThrow(/outside/);
    fs.symlinkSync("/etc", path.join(repo, "link"));
    expect(() => inside(repo, "link/hosts")).toThrow(/outside/);
    expect(inside(repo, "src/b.ts")).toBe(path.join(fs.realpathSync(repo), "src", "b.ts"));
  });
  it("lists changes with status", async () => {
    const c = await changes(repo);
    expect(c.git).toBe(true);
    expect(c.items).toEqual(expect.arrayContaining([{ path: "a.ts", status: "modified" }, { path: "new.md", status: "untracked" }]));
  });
  it("reads current and committed text for the diff, and saves", async () => {
    const r = await readFile(repo, "a.ts");
    expect(r.original).toBe("export const a = 1;\n");
    expect(r.current).toBe("export const a = 2;\n");
    writeFile(repo, "a.ts", "export const a = 3;\n");
    expect(fs.readFileSync(path.join(repo, "a.ts"), "utf8")).toBe("export const a = 3;\n");
    expect(() => writeFile(repo, "../x.txt", "no")).toThrow(/outside/);
  });
  it("quick open finds files", async () => {
    expect(await listFiles(repo, "b.t")).toEqual(["src/b.ts"]);
  });
  it("works in a folder that is not a git repo", async () => {
    const plain = fs.mkdtempSync(path.join(os.tmpdir(), "sd-plain-"));
    fs.writeFileSync(path.join(plain, "x.py"), "print(1)\n");
    expect((await changes(plain)).git).toBe(false);
    expect((await readFile(plain, "x.py")).original).toBeNull();
    expect(await listFiles(plain, "")).toEqual(["x.py"]);
  });
});

describe("binary files", () => {
  it("are refused by name, even when their first bytes look like text", async () => {
    fs.writeFileSync(path.join(repo, "doc.pdf"), "%PDF-1.4\nplain looking\n");
    expect((await readFile(repo, "doc.pdf")).binary).toBe(true);
  });
});
