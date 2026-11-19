"""Unit tests for the claim checker that need no network or local chats."""
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("claimcheck", pathlib.Path(__file__).parent.parent / "claimcheck" / "claimcheck.py")
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)

def test_redaction():
    fake_gitlab = "glpat" + "-" + "x" * 22          # built at runtime so secret scanners do not flag the test
    r = c.redact("key sk-" + "a" * 20 + " and password: hunter2xyz and " + fake_gitlab)
    assert "sk-abc" not in r and "hunter2" not in r and "glpat-" not in r

def test_claim_words():
    assert c.CLAIM_RE.search("Deployed and verified live")
    assert not c.CLAIM_RE.search("I will look at it")

def test_turn_assembly():
    turns, done = {}, None
    for l in [{"type": "user", "message": {"content": "ship it"}, "cwd": "/x"},
              {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {}}], "usage": {"output_tokens": 5}}},
              {"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}},
              {"type": "assistant", "message": {"content": [{"type": "text", "text": "Done."}], "stop_reason": "end_turn", "usage": {"output_tokens": 7}}}]:
        done = c.feed(turns, "s", l) or done
    assert done is not None and done.tokens_out == 12

if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"): fn(); print("PASS", name)
