import { describe, it, expect } from "vitest";
import { parseText, needsFromFacts, stateFromFacts } from "../src/main/adapters/watch/parse";
import { buildPrompt, parseReport, lastTurn } from "../src/main/checks/checker";
import { reduce, initialState } from "../src/main/core/store";

const line = (o: object) => JSON.stringify(o);
const waiting = (tool: string, input: object) => [
  line({ type: "user", uuid: "u", cwd: "/w", entrypoint: "claude-vscode", message: { role: "user", content: "go" } }),
  line({ type: "assistant", uuid: "a", message: { stop_reason: "tool_use", content: [{ type: "tool_use", id: "t9", name: tool, input }] } }),
].join("\n");

describe("needs you, for chats in other apps", () => {
  it("an unanswered tool call after 8 s of silence needs you", () => {
    const { facts } = parseText(waiting("Bash", { command: "rm -rf dist" }));
    const now = Date.now();
    expect(needsFromFacts(facts, now - 3_000, now)).toBeNull();               // still possibly running
    expect(needsFromFacts(facts, now - 9_000, now)?.summary).toBe("Bash: rm -rf dist");
    expect(stateFromFacts(facts, now - 9_000, now)).toBe("needs-you");
  });

  it("a question to the person counts almost at once", () => {
    const { facts } = parseText(waiting("AskUserQuestion", { questions: [] }));
    const now = Date.now();
    expect(needsFromFacts(facts, now - 2_000, now)?.tool).toBe("AskUserQuestion");
  });

  it("a tool result clears it", () => {
    const text = waiting("Bash", { command: "ls" }) + "\n" +
      line({ type: "user", uuid: "r", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t9", content: "ok" }] } });
    const { facts } = parseText(text);
    expect(needsFromFacts(facts, Date.now() - 60_000)).toBeNull();
  });
});

describe("claim checker", () => {
  const turn = lastTurn([
    { key: "0", role: "user", text: "old" },
    { key: "1", role: "user", text: "Run the tests" },
    { key: "tool-t1", role: "tool", text: "", tool: { name: "Bash", input: "npm test" } },
    { key: "res-t1", role: "result", text: "2 failing", tool: { name: "result", input: "t1", isError: true } },
    { key: "3", role: "assistant", text: "All tests pass." },
  ]);
  it("takes only the last turn and includes the evidence", () => {
    expect(turn[0].text).toBe("Run the tests");
    const p = buildPrompt(turn);
    expect(p).toContain("TOOL RESULT for t1 (ERROR): 2 failing");
    expect(p).toContain("ASSISTANT: All tests pass.");
  });
  it("parses verdicts and keeps the follow-up only when something is unsupported", () => {
    const r = parseReport('Here: {"claims":[{"claim":"All tests pass","verdict":"unsupported","why":"2 failing"}],"followup":"Show the passing run."}');
    expect(r.claims[0].verdict).toBe("unsupported");
    expect(r.followup).toBe("Show the passing run.");
    const ok = parseReport('{"claims":[{"claim":"x","verdict":"supported","why":"y"}],"followup":"nope"}');
    expect(ok.followup).toBeUndefined();
    expect(parseReport('{"claims":[{"claim":"x","verdict":"maybe","why":""}]}').claims[0].verdict).toBe("unclear");
  });
});

describe("screenshots belong to the chat they were picked for", () => {
  it("assigns a shot", () => {
    let s = reduce(initialState(), { t: "shot.added", shot: { id: "x", path: "/p.png", createdAt: 1 } });
    s = reduce(s, { t: "shot.patch", id: "x", patch: { sessionId: "chat-1" } });
    expect(s.shots[0].sessionId).toBe("chat-1");
  });
});
