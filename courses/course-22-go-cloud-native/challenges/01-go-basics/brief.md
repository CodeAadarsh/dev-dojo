# Go Fundamentals: WordFreq + Generics

A PR lands in the shared `utils` library. The review comment reads:

> *"We have the same word-count loop in five services and four different slice-map helpers. Consolidate into `WordFreq`, `Map`, and `Filter` here. Make `Map`/`Filter` generic — we're on 1.22; no reason to keep repeating type assertions."*

Your job: implement the three functions in `basics.go` so the test harness passes end-to-end.

## Context

`setup.sh` plants a starter module in your work directory:

```
~/.kube-dojo-work/01-go-basics/
├── go.mod
├── basics.go        # three stub functions — only the bodies are missing
└── basics_test.go   # visible smoke tests you can run locally
```

## Prerequisites

Go 1.22 or later. No external dependencies — the module uses the standard library only.

```bash
go version   # must be >= go1.22
```

## Mission

Implement the three exported functions in `basics.go`:

| Function | Signature | Contract |
|----------|-----------|----------|
| `WordFreq` | `func WordFreq(s string) map[string]int` | Split `s` on whitespace; count each token case-insensitively. Empty string returns an empty map, not nil. |
| `Map` | `func Map[T, U any](in []T, f func(T) U) []U` | Apply `f` to every element; preserve order; empty input returns `[]U{}` (non-nil). |
| `Filter` | `func Filter[T any](in []T, keep func(T) bool) []T` | Return elements where `keep` is true; empty result returns an empty slice (non-nil). |

The verify harness checks these exact contracts, including:

- `WordFreq("Go GO go")` → `{"go": 3}` (case fold)
- `WordFreq("  hello world hello  ")` → `{"hello": 2}` (leading/trailing whitespace)
- `Map([]string{"go", "cloud"}, strings.ToUpper)` → `["GO", "CLOUD"]`
- `Filter([]int{1, 3, 5}, isEven)` → `[]int{}` (no match, not nil)

## Why it matters

`strings.Fields` already handles multi-space splitting; `strings.ToLower` handles case folding. The idiomatic implementation is three lines for `WordFreq`. The interesting part is `Map` and `Filter` — before Go generics (1.18+) you needed `reflect` or a separate function per type. Generics give you real parametric polymorphism: one `Map` that works for `[]int → []string`, `[]float64 → []float64`, `[]Job → []Result` — all resolved at compile time, zero runtime overhead.

## Verify

```bash
bash courses/course-22-go-cloud-native/challenges/01-go-basics/verify.sh
```

All tests green → flag printed.
