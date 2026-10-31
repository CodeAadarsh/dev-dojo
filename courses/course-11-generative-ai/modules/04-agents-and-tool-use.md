# Agents & Tool Use

> **Module 04 · Course 11** — A single prompt with a perfect system message will outperform a twelve-step agent on most tasks. Know when the overhead is worth it, then build agents that don't eat themselves.

You already know how to call an LLM. This module is about making that LLM call *other things* — APIs, databases, code interpreters — and chain those calls intelligently without giving up control.

---

## When agents beat a single prompt (and when they don't)

The question isn't "can I build an agent for this?" — you always can. The question is whether the routing overhead, error surface, and latency are worth it.

```
Single prompt wins when:
  ┌─────────────────────────────────────────────────────────────┐
  │  Task is bounded: "summarize this PR", "classify this log"  │
  │  All required context fits comfortably in one call           │
  │  Latency matters: streaming > 3-hop agent for chat UI        │
  │  You can verify correctness by inspection                    │
  └─────────────────────────────────────────────────────────────┘

Agents win when:
  ┌─────────────────────────────────────────────────────────────┐
  │  Task requires live data the model can't know (search, DB)  │
  │  Execution requires side effects (file write, API call)     │
  │  Steps are data-dependent: can't plan until step N returns  │
  │  Task decomposes into parallel sub-tasks (fan-out + join)   │
  └─────────────────────────────────────────────────────────────┘
```

A common mistake is adding tool calls to avoid retraining: "the model doesn't know our internal prices, so let's give it a search tool." That's valid. Giving it eight tools to avoid writing a system prompt that has the answer is not.

> **Cost signal:** every tool call adds at minimum one round-trip to the LLM (tool-call turn + observation turn). A three-step agent at 2 s/LLM-call costs 6 s just in LLM latency, before execution time. Always benchmark the single-prompt baseline first.

---

## How tool calling works mechanically

The LLM never "runs" a tool — it outputs structured JSON that *you* execute, then re-inject as context. The model's side is a formatted output problem.

### The tool schema (OpenAI / Anthropic format)

```python
tools = [
    {
        "name": "search_docs",
        "description": (
            "Full-text search over the internal engineering docs. "
            "Use when the question requires current internal policy or specs. "
            "Do NOT use for general knowledge questions the model already knows."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The search query. Be specific; avoid filler words."
                },
                "max_results": {
                    "type": "integer",
                    "description": "Number of results to return (1–10).",
                    "default": 5
                }
            },
            "required": ["query"]
        }
    }
]
```

The description is the model's entire signal for when to call this tool vs. another. Write it like a senior engineer wrote it for a junior who will take it literally — because the model will.

### The round-trip

```
User message
     │
     ▼
LLM call (tools=[...])
     │
     ▼  model outputs: {"type":"tool_use","name":"search_docs","input":{...}}
Your code executes search_docs(...)
     │
     ▼  you append: {"type":"tool_result","tool_use_id":"...","content":"..."}
LLM call (same messages + tool_result appended)
     │
     ▼  model outputs a final text response
```

Nothing in that loop is autonomous — you control whether to execute, what to execute, and what result to return. This is where guardrails live.

```python
import anthropic

client = anthropic.Anthropic()

def run_agent(user_message: str, max_iterations: int = 10) -> str:
    messages = [{"role": "user", "content": user_message}]
    iterations = 0

    while iterations < max_iterations:
        iterations += 1
        response = client.messages.create(
            model="claude-sonnet-4-5",
            max_tokens=4096,
            tools=tools,
            messages=messages,
        )

        # Model is done — no tool calls
        if response.stop_reason == "end_turn":
            return next(
                b.text for b in response.content if b.type == "text"
            )

        # Execute tool calls and collect results
        tool_results = []
        for block in response.content:
            if block.type == "tool_use":
                result = dispatch_tool(block.name, block.input)  # your fn
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": str(result),
                })

        # Append assistant turn + tool results as user turn
        messages.append({"role": "assistant", "content": response.content})
        messages.append({"role": "user", "content": tool_results})

    raise RuntimeError(f"Agent exceeded {max_iterations} iterations without finishing")
```

The `max_iterations` guard is not optional — it's the difference between a buggy agent and an infinite billing loop.

---

## The ReAct loop

ReAct (Reason + Act) is the canonical agentic pattern. The model interleaves thinking and acting in one stream rather than producing a plan upfront that can't adapt.

```
[User] What's the on-call rotation for the payments team this week?

[Thought] I need to query PagerDuty for the current schedule.
[Action]  get_oncall_schedule(team="payments", week="current")
[Obs]     {"primary": "alice@co", "secondary": "bob@co", "from": "Mon", "to": "Sun"}

[Thought] I have the schedule. No further lookups needed.
[Answer]  This week's payments on-call: primary Alice, secondary Bob (Mon–Sun).
```

The "thought" blocks are either explicit scratchpad tokens in the prompt (`<thinking>` in Claude's extended thinking) or implicit (the model reasons inside its context before selecting a tool). For most production agents, **implicit is cheaper and fast enough**. Use extended thinking only when the task requires multi-step logical deduction where intermediate reasoning errors compound.

### When to make planning explicit

For tasks with more than ~5 steps, have the agent produce a plan first, confirm it (or validate it programmatically), then execute:

```python
PLANNER_PROMPT = """
Given the user's goal, output a JSON plan:
{
  "steps": [
    {"id": 1, "tool": "tool_name", "args": {...}, "depends_on": []},
    {"id": 2, "tool": "tool_name", "args": {...}, "depends_on": [1]}
  ]
}
Only include steps that require tool calls. Steps with no depends_on can run in parallel.
"""

# Step 1: generate plan
plan = call_llm(system=PLANNER_PROMPT, user=goal)

# Step 2: validate plan (reject unknown tools, circular deps, etc.)
validate_plan(plan)

# Step 3: execute — parallel where depends_on is empty
import asyncio
results = asyncio.run(execute_plan(plan, tools))
```

Parallel execution matters at scale: a 4-step agent where steps 2, 3, 4 are independent drops from 8 s to 2 s with asyncio.

---

## Memory

Every agent call starts with a blank context window. "Memory" is your infrastructure for what survives between turns.

| Memory type | Where | What goes there | Implementation |
|-------------|-------|-----------------|----------------|
| In-context | `messages[]` | Full conversation history, current task context | Just append — until you hit the context limit |
| Episodic (external) | Vector store | Past interactions, retrieved by semantic similarity | Embed + store in Chroma/Qdrant; fetch top-k before each call |
| Semantic (external) | Key-value | Extracted facts: user preferences, last known state | Redis / DynamoDB; explicit read/write tool |
| Procedural | System prompt | Agent persona, tool use rules, output format | Static or dynamically assembled at call time |

Context compression is how you keep long-running agents from running out of window:

```python
def compress_history(
    messages: list[dict],
    keep_last_n: int = 6,
    model: str = "claude-haiku-4-5",
) -> list[dict]:
    if len(messages) <= keep_last_n:
        return messages

    to_compress = messages[:-keep_last_n]
    recent = messages[-keep_last_n:]

    summary = client.messages.create(
        model=model,
        max_tokens=512,
        system="Summarize the following conversation turns into a brief context paragraph. Be factual, not conversational.",
        messages=[{"role": "user", "content": str(to_compress)}],
    ).content[0].text

    compressed = [
        {"role": "user", "content": f"[Prior context summary]: {summary}"}
    ]
    return compressed + recent
```

Call this before each LLM turn when `len(messages) > threshold`. Use a cheap/fast model for summarization — spending Claude Sonnet tokens to summarize old tool results is wasteful.

---

## Guarding tool side effects

Any tool that writes, deletes, sends, or charges money needs a gate. The model is a statistical system; it will occasionally call a destructive tool at the wrong time.

### Defense in depth

```python
# 1. Tool-level: explicit confirmation for irreversible actions
def send_email(to: str, subject: str, body: str) -> dict:
    if not CONFIRM_GATE.approved(action="send_email", args={"to": to}):
        return {"status": "pending_approval", "token": CONFIRM_GATE.request(...)}
    # proceed only after human or automated approval
    return _actually_send(to, subject, body)

# 2. Dry-run mode: shadow-execute without side effects
def delete_records(table: str, where: str, dry_run: bool = True) -> dict:
    if dry_run:
        count = db.count(f"SELECT count(*) FROM {table} WHERE {where}")
        return {"would_delete": count, "dry_run": True}
    return {"deleted": db.execute(f"DELETE FROM {table} WHERE {where}")}

# 3. Idempotency keys: safe to retry
def charge_customer(customer_id: str, amount_cents: int, idempotency_key: str) -> dict:
    return stripe.charges.create(
        amount=amount_cents,
        currency="inr",
        customer=customer_id,
        idempotency_key=idempotency_key,  # Stripe deduplicates
    )
```

### Tool privilege separation

Don't give one agent all tools. Compose specialized agents:

```
OrchestratorAgent (read-only tools only)
    │
    ├── DataAgent (read: DB, vector store, search)
    ├── WriterAgent (write: DB, files)   ← requires explicit delegation
    └── NotifierAgent (send: email, Slack) ← requires explicit delegation
```

The orchestrator decides *what* to do; privileged sub-agents do the *execution* after the orchestrator's decision is logged and optionally approved. This is the principle of least privilege applied to agents.

---

## Debugging Agents

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Agent loops calling the same tool with same args | Tool result doesn't change the model's state; termination condition missing | Add a `seen_tool_calls` set; if identical (name, args) repeats, inject: "You already called this. If it didn't help, use a different approach or respond with what you know." |
| Agent calls the wrong tool consistently | Tool descriptions overlap or are underspecified | Rewrite descriptions with contrasting "use when X, NOT when Y" sentences; add 1–2 few-shot examples in the system prompt |
| Agent context window hits limit mid-task | Tool results are large (full doc bodies, DB dumps) | Truncate tool outputs at injection: `result[:2000] + "...[truncated]"`. Or add a `summarize_tool_result` postprocessor |
| Agent finishes but skips required steps | Model found a shortcut path; planning was implicit | Make planning explicit (see above); add a checklist in system prompt that the model must tick off |
| Tool is called with invalid args; crashes | Model hallucinated an arg name or value | Add Pydantic validation at the tool dispatch layer; return a structured error JSON the model can recover from, not a Python traceback |
| Agent succeeds in dev, fails in prod | Tool latency increased; LLM timeout cuts the loop short | Set `timeout` per tool call; handle `TimeoutError` gracefully; return partial results with a note |

### Exact diagnostic commands

```bash
# Dump every message in the agent loop to a file for post-mortem
AGENT_TRACE=1 python agent.py 2>&1 | tee /tmp/agent-trace.log

# Count tool calls per tool name from a trace log
grep '"name":' /tmp/agent-trace.log | sort | uniq -c | sort -rn

# Check token usage per LLM call (Anthropic SDK response)
python3 -c "
import json, sys
for line in sys.stdin:
    if 'usage' in line:
        print(json.loads(line.strip())['usage'])
" < /tmp/agent-trace.log
```

For context bloat, measure before each call:

```python
import anthropic

def estimate_tokens(messages: list[dict]) -> int:
    # Anthropic SDK token counting (free, doesn't bill)
    return client.messages.count_tokens(
        model="claude-sonnet-4-5",
        messages=messages,
        tools=tools,
    ).input_tokens

# Warn before the call if you're burning too much context
tokens = estimate_tokens(messages)
if tokens > 80_000:  # 80k out of 200k limit = time to compress
    messages = compress_history(messages)
```

> **War story.** At SAP, an internal support agent started calling the same `get_ticket_details` tool 40 times in a loop on a particular class of Jira ticket. Tracing showed the tool returned HTML in certain edge cases (the Jira REST endpoint returned a redirect page instead of JSON when the session token expired). The model kept retrying because it couldn't parse the result, not because it was confused about *what* to call. Fix: add session-token refresh logic to the tool, and add explicit error handling that returns `{"error": "auth_expired", "message": "..."}` — the model immediately switched to asking the user to re-authenticate instead of looping. The root cause was the tool's contract being poorly defined at the error boundary, not the model's behavior.

---

## Checkpoint

You're ready for the agents challenges when you can, without looking anything up:

1. Describe the full tool-calling round-trip: what the model outputs, what your code does, what gets appended to the message list.
2. Write the `max_iterations` guard for an agent loop and explain why omitting it is a billing risk.
3. Explain the difference between in-context, episodic, and semantic memory. Give one concrete use case for each.
4. Write a ReAct trace (Thought / Action / Observation / Answer) for a two-step task of your choice.
5. Name two reasons a model might call the wrong tool, and one fix for each.
6. Design the privilege separation for an agent that reads from a Postgres DB and sends Slack notifications. Which agent gets which tools?
7. Implement a context-compression function that keeps the last N messages and summarizes the rest using a cheap model.
8. Explain what `idempotency_key` buys you and when you'd add it to a tool.

➡ Next: **Evaluation & Guardrails** — the discipline of knowing whether your agent (or any LLM system) is actually working, and the defenses that keep it from going sideways in production.
