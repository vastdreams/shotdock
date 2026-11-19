import { describe, it, expect } from "vitest";
import { parseText, stateFromFacts, emptyFacts } from "../src/main/adapters/watch/parse";
import { parseCursor } from "../src/main/adapters/watch/cursorAgents";

// A redacted, hand-trimmed Claude Code transcript with every line type the parser cares about, plus noise.
const T = [
  { type: "session-owner", sessionId: "s1" },
  { type: "user", uuid: "u1", sessionId: "s1", cwd: "/work/app", entrypoint: "claude-vscode", timestamp: "2026-11-19T10:00:00Z",
    message: { role: "user", content: [{ type: "text", text: "Fix the login bug" }, { type: "image", source: {} }] } },
  { type: "assistant", uuid: "a1", timestamp: "2026-11-19T10:00:05Z",
    message: { model: "claude-opus-5-5", stop_reason: "tool_use", content: [{ type: "thinking", thinking: "" },
      { type: "text", text: "Looking at it." }, { type: "tool_use", id: "t1", name: "Bash", input: { command: "npm test" } }] } },
  { type: "user", uuid: "u2", timestamp: "2026-11-19T10:00:09Z",
    message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "1 failing", is_error: true }] } },
  { type: "assistant", uuid: "sub", isSidechain: true, message: { content: [{ type: "text", text: "subagent noise" }] } },
  { type: "ai-title", aiTitle: "Login bug fix" },
  { type: "api-request", id: "x" },
  { type: "assistant", uuid: "a2", timestamp: "2026-11-19T10:01:00Z",
    message: { model: "claude-opus-5-5", stop_reason: "end_turn", content: [{ type: "text", text: "Fixed. Tests pass." }] } },
].map((o) => JSON.stringify(o)).join("\n") + "\n{\"type\":\"user\",\"half-written";

describe("Claude Code transcript parser", () => {
  const { items, facts } = parseText(T);

  it("extracts facts", () => {
    expect(facts.sessionId).toBe("s1");
    expect(facts.cwd).toBe("/work/app");
    expect(facts.entrypoint).toBe("claude-vscode");
    expect(facts.title).toBe("Login bug fix");
    expect(facts.model).toBe("claude-opus-5-5");
    expect(facts.lastStop).toBe("end_turn");
  });

  it("produces items in order, skipping sidechains, thinking and noise", () => {
    expect(items.map((i) => i.role)).toEqual(["user", "assistant", "tool", "result", "assistant"]);
    expect(items[0]).toMatchObject({ text: "Fix the login bug", images: 1 });
    expect(items[2].tool).toMatchObject({ name: "Bash", input: "npm test" });
    expect(items[3].tool).toMatchObject({ isError: true, output: "1 failing" });
    expect(items.some((i) => i.text.includes("subagent"))).toBe(false);
  });

  it("custom titles beat ai titles", () => {
    const { facts: f } = parseText(T + "\n" + JSON.stringify({ type: "custom-title", customTitle: "Mine" }) + "\n", emptyFacts());
    expect(f.title).toBe("Mine");
  });

  it("infers state", () => {
    expect(stateFromFacts(facts, Date.now())).toBe("idle");                       // finished turn
    const busy = { ...facts, lastStop: "tool_use" };
    expect(stateFromFacts(busy, Date.now() - 5_000)).toBe("working");
    expect(stateFromFacts(busy, Date.now() - 600_000)).toBe("idle");
  });
});

describe("Cursor agent transcript parser", () => {
  it("reads user queries and assistant text", () => {
    const text = [
      { role: "user", message: { content: [{ type: "text", text: "<timestamp>x</timestamp>\n<user_query>\nWrite the launch plan\n</user_query>" }] } },
      { role: "assistant", message: { content: [{ type: "text", text: "Drafting." }] } },
    ].map((o) => JSON.stringify(o)).join("\n");
    expect(parseCursor(text)).toEqual([{ key: "c0", role: "user", text: "Write the launch plan" }, { key: "c1", role: "assistant", text: "Drafting." }]);
  });
});

describe("tool paths", () => {
  it("are shown relative to the chat folder", () => {
    const t = [
      JSON.stringify({ type: "user", uuid: "u", cwd: "/home/me/app", message: { role: "user", content: "x" } }),
      JSON.stringify({ type: "assistant", uuid: "a", message: { stop_reason: "tool_use", content: [{ type: "tool_use", id: "t", name: "Read", input: { file_path: "/home/me/app/src/a.ts" } }] } }),
    ].join("\n");
    expect(parseText(t).items[1].tool?.input).toBe("src/a.ts");
  });
});
