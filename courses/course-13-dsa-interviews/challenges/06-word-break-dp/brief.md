# Word Break

A search service uses a custom tokenizer to split user queries into known terms before passing them to an embedding model. The tokenizer has a bug: it crashes on inputs that cannot be segmented into dictionary words instead of returning an empty result. You're writing the core segmentation check.

Given a string `s` and a list of dictionary words `word_dict`, return `True` if `s` can be segmented into a space-separated sequence of one or more words from `word_dict`, `False` otherwise. Words in `word_dict` may be reused any number of times.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/06-word-break-dp/
├── solution.py          # two stubs: word_break_memo and word_break_tab
└── tests/
    └── test_word_break.py  # eight-test harness you can run locally
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/06-word-break-dp
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement **both** functions in `solution.py`:

- `word_break_memo(s: str, word_dict: list[str]) -> bool` — memoized recursion (top-down DP)
- `word_break_tab(s: str, word_dict: list[str]) -> bool` — tabulation (bottom-up DP)

Both must produce identical results. The verifier tests them independently.

## Examples

```
word_break_memo("leetcode",  ["leet", "code"])        # True  → "leet" + "code"
word_break_memo("applepenapple", ["apple", "pen"])    # True  → "apple" + "pen" + "apple"
word_break_memo("catsandog",  ["cats", "dog", "sand", "and", "cat"])  # False
word_break_tab("cars",  ["car", "ca", "rs"])          # True  → "ca" + "rs"
```

## Why both forms matter

`word_break_memo` and `word_break_tab` solve the same subproblem set — "can `s[i:]` be segmented?" (memo) vs "can `s[:i]` be segmented?" (tab) — but in opposite directions. Interviewers ask for one and then ask you to translate to the other. If you can only produce one form, you haven't understood DP; you've memorized a solution.

## Verify

```bash
bash courses/course-13-dsa-interviews/challenges/06-word-break-dp/verify.sh
```

All tests green → flag printed.
