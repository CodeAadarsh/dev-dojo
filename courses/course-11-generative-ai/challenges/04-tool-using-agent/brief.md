# Tool-Using Agent

A teammate's PR comment reads: *"the agent answers stock questions by making up numbers — it never actually calls the price-lookup tool. The loop exits after the first model response regardless of whether it asked for a tool."* Classic off-by-one in the agentic loop: the code checks the response type once, not in a loop.

This challenge makes that concrete. You get a deterministic mock model, a real tool registry, and a skeleton loop. You implement the loop. The verifier runs a hidden pytest suite that asserts the tools were invoked AND the final answer equals the known-correct value.

## How function-calling works

The model doesn't call tools directly — it returns a structured response saying *"please call tool X with args Y and give me the result."* The agent loop is responsible for:

1. Sending the conversation to the model.
2. Inspecting the response type.
3. If `tool_call`: dispatch to the correct tool, collect the result, append it to the message history, go back to step 1.
4. If `text`: the model is done — return the final answer.

A loop that exits after step 2 unconditionally is the most common beginner bug. A loop that never appends the tool result to messages is the second most common — the model can't see what it returned and spirals.

## Work directory layout

`setup.sh` plants the following in `~/.kube-dojo-work/04-tool-using-agent/`:

```
tools.py        # lookup_stock_price(ticker) — records calls in CALL_LOG
mock_model.py   # scripted 3-response sequence (no LLM needed)
agent.py        # run_agent(question) skeleton — implement the loop here
sample_test.py  # two lightweight checks you can run while developing
```

## Mission

Implement `run_agent(question: str) -> str` in `agent.py`.

The function must:

1. Build a `messages` list starting with `{"role": "user", "content": question}`.
2. Loop: call `chat(messages)` from `mock_model`.
3. If the response is `{"type": "tool_call", "tool": "...", "args": {...}}`:
   - Look up the tool in `TOOL_REGISTRY`.
   - Call it with `**response["args"]`.
   - Append `{"role": "tool", "content": str(result)}` to `messages`.
   - Continue the loop.
4. If the response is `{"type": "text", "content": "..."}`:
   - Return `response["content"]`.

The mock model drives a fixed two-tool-call scenario: it asks for the price of `AAPL`, then `GOOG`, then synthesises a final text answer. Your loop must handle both calls.

## What the verifier checks

| Check | Pass condition |
|-------|---------------|
| `lookup_stock_price("AAPL")` was called | `"AAPL"` in `tools.CALL_LOG` |
| `lookup_stock_price("GOOG")` was called | `"GOOG"` in `tools.CALL_LOG` |
| Model called exactly 3 times | `mock_model._call_count == 3` |
| Final answer contains `"2900"` | model's computed value for 10×AAPL + 5×GOOG |

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-tool-using-agent
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Run during development

```bash
cd ~/.kube-dojo-work/04-tool-using-agent
.venv/bin/pytest sample_test.py -v
```

## Verify

```bash
bash courses/course-11-generative-ai/challenges/04-tool-using-agent/verify.sh
```
