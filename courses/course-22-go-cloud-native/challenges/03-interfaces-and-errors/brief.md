# Interfaces and Sentinel Errors

A bug report from the namespace-routing layer:

> *"We're wrapping our store errors with context (`fmt.Errorf("lookup %q: %w", key, err)`) but the HTTP middleware that checks `errors.Is(err, store.ErrNotFound)` never matches — it always falls through to a 500. Also, can we add a `PrefixStore` so each tenant gets an isolated namespace without changing the caller interface?"*

Your job: implement the `Store` interface with two backends and correct error wrapping so the full test harness passes.

## Context

`setup.sh` plants a starter module in your work directory:

```
~/.kube-dojo-work/03-interfaces-and-errors/
├── go.mod
├── store.go        # ErrNotFound + Store interface declared; two constructors stubbed
└── store_test.go   # visible smoke tests you can run locally
```

## Prerequisites

Go 1.22 or later. No external dependencies.

```bash
go version   # must be >= go1.22
```

## Mission

Implement the two constructors and their backing types in `store.go`:

| Constructor | Contract |
|-------------|----------|
| `NewMemoryStore() Store` | In-memory map. `Set` overwrites. `Get` returns a wrapped `ErrNotFound` on miss. `Delete` is a no-op on absent keys. |
| `NewPrefixStore(prefix string, inner Store) Store` | Delegates to `inner`, prepending `prefix` to every key. Does NOT own storage. |

The verifier checks:

- `errors.Is(err, ErrNotFound)` returns `true` for a missing key.
- `errors.Is` returns `true` even when the returned error is **wrapped again** by the caller (`fmt.Errorf("outer: %w", err)`).
- `PrefixStore` physically stores `prefix+key` in the inner store.
- Two `PrefixStore` instances on the same inner store with different prefixes do not interfere (`p1.Set("x",...)` and `p2.Set("x",...)` are independent namespaces).
- Both implementations satisfy the `Store` interface and are interchangeable at the interface type.

## Why it matters

**Interface-based design** means you can swap `MemoryStore` for a Redis-backed store, a read-through cache, or a test double without changing any caller. The pattern is the foundation of hexagonal architecture and every Go testing strategy that avoids hitting real infrastructure.

**Sentinel errors + `%w`** is the canonical Go error model since 1.13. The key insight: `errors.Is` unwraps the error chain recursively, so `fmt.Errorf("operation failed: %w", ErrNotFound)` still matches `errors.Is(err, ErrNotFound)`. The mistake everyone makes once: `fmt.Errorf("...: %v", err)` — `%v` embeds the string, not the error value, so `errors.Is` can't unwrap it.

## Verify

```bash
bash courses/course-22-go-cloud-native/challenges/03-interfaces-and-errors/verify.sh
```

All tests green → flag printed.
