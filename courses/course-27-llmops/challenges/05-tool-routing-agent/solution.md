# Solution — Tool Routing Agent

## The complete `run_agent()` implementation

```python
def run_agent(query: str, max_steps: int = 5) -> str:
    history = []
    for _ in range(max_steps):
        action = MOCK_PLANNER(query, history)

        if action["action"] == "answer":
            return action["value"]

        if action["action"] == "tool_call":
            tool_name = action["tool"]
            if tool_name not in TOOLS:
                raise ValueError(f"Unknown tool: {tool_name!r}")
            result = TOOLS[tool_name](**action["args"])
            history.append({
                "tool":   tool_name,
                "args":   action["args"],
                "result": result,
            })
        else:
            raise ValueError(f"Unknown action type: {action['action']!r}")

    raise StepBudgetExceeded(
        f"Agent did not return an answer within max_steps={max_steps}"
    )
```

## Why each piece is correct

**`history` as the state carrier.**
The planner is stateless — it receives `(query, history)` and returns the next action. Every tool call's result must be appended to `history` before the next `MOCK_PLANNER` call. In the chain test, step 1's planner call uses `history[0]["result"]` (the city name from the lookup) to build the calculator expression. If history is never updated, the planner sees `step = len(history) == 0` on every iteration and returns the same `tool_call` forever — consuming the entire step budget.

**`for _ in range(max_steps)` with fall-through raise.**
A `while True` loop without an explicit counter is dangerous for the same reason the post-mortem describes. `range(max_steps)` gives a hard ceiling; the `raise StepBudgetExceeded` after the loop runs when the loop exhausts all iterations without hitting a `return`. This is cleaner than an incrementing counter inside a `while True`.

**Checking `tool_name not in TOOLS` before calling.**
`TOOLS[tool_name]` raises `KeyError` for an unknown tool, which is acceptable per the test (`pytest.raises((ValueError, KeyError))`). Raising `ValueError` explicitly with a message is better practice: it signals a contract violation (invalid tool name) rather than an implementation detail (dict key miss).

**Dispatch via `TOOLS[tool_name](**action["args"])`.**
Passing args as keyword arguments means the mock tools receive named parameters (`expr=`, `key=`) as declared, and a planner that generates wrong arg keys produces a descriptive `TypeError` instead of a silent mismatch.

## Trace through the chain test

Query: `"chain: capital then length"`, `max_steps=5`

| Step | `MOCK_PLANNER` returns | Tool called | Result | history length |
|------|----------------------|-------------|--------|----------------|
| 0 | `tool_call lookup spain_capital` | `_lookup("spain_capital")` | `"Madrid"` | 1 |
| 1 | `tool_call calculator 6` (len("Madrid")) | `_calculator("6")` | `6.0` | 2 |
| 2 | `answer "6"` | — | — | 2 |

Return value: `"6"`. Without history fed back, `step = 0` at every iteration and the chain never advances past the lookup.

## Production considerations

Real agentic systems extend this loop with:
- **Parallel tool calls.** When the planner's output contains multiple independent tool calls (common in function-calling APIs), dispatch them concurrently and merge results.
- **Tool output truncation.** Real tools return unbounded text; truncate at a token limit before appending to history to avoid context-window overflow.
- **Retry with backoff.** Tool failures should be caught, added to history as error results, and re-presented to the planner rather than crashing the loop.
- **Cost tracking.** Each planner call is an LLM call. Emit a metric per step; alert when a single query chain exceeds a cost threshold.

## Apply and verify

```bash
cd ~/.kube-dojo-work/05-tool-routing-agent
# replace run_agent() with the solution above, then:
.venv/bin/pytest tests/ -v
bash courses/course-27-llmops/challenges/05-tool-routing-agent/verify.sh
```
