# Solution — Tool-Using Agent

## The complete `agent.py`

```python
from mock_model import chat
import tools

TOOL_REGISTRY = {
    "lookup_stock_price": tools.lookup_stock_price,
}


def run_agent(question: str) -> str:
    messages = [{"role": "user", "content": question}]

    while True:
        response = chat(messages)

        if response["type"] == "tool_call":
            tool_fn = TOOL_REGISTRY[response["tool"]]
            result = tool_fn(**response["args"])
            messages.append({"role": "tool", "content": str(result)})

        elif response["type"] == "text":
            return response["content"]

        else:
            raise ValueError(f"unknown response type: {response['type']!r}")
```

## Why each piece is necessary

**`while True` loop, not `if`.**
The single most common bug is `if response["type"] == "tool_call": ... return response["content"]`. That exits after the first response regardless of type. An agent that needs two tool calls would return on the first tool-call response instead of continuing. `while True` with an explicit `return` on `"text"` is the correct pattern.

**Appending the tool result to `messages`.**
The mock model's third response is scripted, but a real LLM needs the tool output in the message history to synthesise a grounded answer. If you dispatch the tool but don't append its result, the model's next call receives a conversation with a dangling tool_call and no follow-up — most models will either error or ignore the missing data and hallucinate. The append is not optional.

**`**response["args"]`.**
The tool takes named arguments (`ticker=`). Unpacking the args dict gives clean keyword-argument dispatch and works for any tool signature. Alternatively, `tool_fn(response["args"]["ticker"])` works for this specific tool but breaks the moment the args schema changes.

**`TOOL_REGISTRY` as an indirection layer.**
Hard-coding `tools.lookup_stock_price(...)` inside the loop couples the agent to a specific tool. Using a registry keyed by the name string the model returns means you can add tools without touching the loop — the model just starts returning new `"tool"` values.

## Trace the three-call sequence

| Call | `chat()` returns | Action |
|------|-----------------|--------|
| 1 | `{type: tool_call, tool: lookup_stock_price, args: {ticker: AAPL}}` | call `lookup_stock_price("AAPL")` → `150.0`, append to messages |
| 2 | `{type: tool_call, tool: lookup_stock_price, args: {ticker: GOOG}}` | call `lookup_stock_price("GOOG")` → `280.0`, append to messages |
| 3 | `{type: text, content: "The combined value is $2900.00 ..."}` | return the string |

10 × 150.0 + 5 × 280.0 = 1500 + 1400 = **2900**.

## Production note

In production, tool calls arrive as JSON in the model's response body (OpenAI function-calling, Anthropic tool_use, etc.). The loop structure is identical — the only difference is the parsing layer that converts the raw API response into a dict like the one mock_model returns. The `messages` list maps directly to the `messages` parameter of the API.
