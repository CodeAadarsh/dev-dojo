# Tool Routing Agent

A post-mortem on a production agent outage reads: *"The agent kept calling the weather tool in a loop because the result was never fed back to the planner. After 10,000 tool calls and a $200 API bill, the instance OOM-killed itself."*

Two bugs: the history list was never updated, and there was no step budget. Both are yours to fix — except in this challenge the planner and tools are already provided as deterministic mocks, so you only implement the loop.

## Context

`setup.sh` plants a work directory:

```
~/.kube-dojo-work/05-tool-routing-agent/
├── agent.py          # MOCK_PLANNER, TOOLS, StepBudgetExceeded are provided
│                     # implement run_agent() only
└── tests/
    └── test_agent.py # six-test harness; all must pass
```

No cluster, no network, no API keys. The planner and tools are pure Python with fixed behaviour.

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-tool-routing-agent
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement `run_agent(query, max_steps)` in `agent.py`:

1. Call `MOCK_PLANNER(query, history)` to get the next action dict.
2. If `action["action"] == "tool_call"`: look up the tool in `TOOLS` by `action["tool"]`, call it with `**action["args"]`, append `{"tool": ..., "args": ..., "result": ...}` to `history`, and loop.
3. If `action["action"] == "answer"`: return `action["value"]`.
4. If `max_steps` tool calls have been made with no answer yet: raise `StepBudgetExceeded`.
5. If the planner names a tool not in `TOOLS`: raise `ValueError`.

The exact conditions `verify.sh` checks:

| Test | What it asserts |
|------|-----------------|
| `test_routes_to_calculator` | `run_agent("what is 6 multiplied by 7")` returns `"42"` |
| `test_routes_to_lookup` | `run_agent("capital of japan")` returns `"Tokyo"` |
| `test_two_step_chain` | `run_agent("chain: capital then length")` returns `"6"` (uses both tools) |
| `test_step_budget_enforced` | `run_agent("infinite_loop", max_steps=3)` raises `StepBudgetExceeded` |
| `test_budget_not_exceeded_on_normal_query` | A 1-tool query completes with `max_steps=10` |
| `test_unknown_tool_raises` | A planner naming a non-existent tool raises `ValueError` or `KeyError` |

## Why step budgets are non-negotiable

Every agentic loop needs a finite hard ceiling on iterations. Without one:

- A planner bug (returning `tool_call` when it meant `answer`) becomes an infinite loop.
- An adversarial prompt that keeps extending the chain runs until money, memory, or latency limits kill the process — after real cost has been incurred.
- Deterministic tools (like a calculator) still spend time; probabilistic tools (real LLM calls) spend both time and money on every step.

The budget is a circuit breaker, not a feature. Setting it requires knowing your expected chain depth for the hardest legitimate query, then multiplying by a safety factor. A budget of 2× the expected max chain depth is a common starting point. When the budget is exceeded, you surface a `StepBudgetExceeded` error to the caller — never silently return a partial answer.

## Verify

```bash
bash courses/course-27-llmops/challenges/05-tool-routing-agent/verify.sh
```

All six tests green → flag printed.
