# Solution — Interfaces and Sentinel Errors

Complete `store.go`. Copy this in, then run the verifier.

```go
package store

import (
	"errors"
	"fmt"
)

var ErrNotFound = errors.New("not found")

type Store interface {
	Set(key, value string)
	Get(key string) (string, error)
	Delete(key string)
}

// ── MemoryStore ──────────────────────────────────────────────────────────────

type memoryStore struct {
	data map[string]string
}

func NewMemoryStore() Store {
	return &memoryStore{data: make(map[string]string)}
}

func (m *memoryStore) Set(key, value string) {
	m.data[key] = value
}

func (m *memoryStore) Get(key string) (string, error) {
	v, ok := m.data[key]
	if !ok {
		return "", fmt.Errorf("Get %q: %w", key, ErrNotFound)
	}
	return v, nil
}

func (m *memoryStore) Delete(key string) {
	delete(m.data, key)
}

// ── PrefixStore ──────────────────────────────────────────────────────────────

type prefixStore struct {
	prefix string
	inner  Store
}

func NewPrefixStore(prefix string, inner Store) Store {
	return &prefixStore{prefix: prefix, inner: inner}
}

func (p *prefixStore) Set(key, value string) {
	p.inner.Set(p.prefix+key, value)
}

func (p *prefixStore) Get(key string) (string, error) {
	return p.inner.Get(p.prefix + key)
}

func (p *prefixStore) Delete(key string) {
	p.inner.Delete(p.prefix + key)
}
```

## Why each piece is correct

**`fmt.Errorf("Get %q: %w", key, ErrNotFound)`** — the `%w` verb wraps the
error value into the new error's chain. `errors.Is` walks that chain
recursively, so any number of additional `fmt.Errorf("...: %w", err)` wraps by
callers still resolve back to `ErrNotFound`. The alternative, `%v`, embeds only
the string representation — `errors.Is` cannot unwrap it, so the chain breaks
and all middleware checking `errors.Is(err, ErrNotFound)` falls through to 500.

**`delete(m.data, key)`** — Go's built-in `delete` is a no-op when the key is
absent. No existence check needed. Trying to `delete` a missing key does NOT
panic (unlike a map write to a nil map, which does).

**`return &memoryStore{data: make(map[string]string)}`** — returning the pointer
type satisfies `Store` because all three methods are defined on `*memoryStore`.
Returning by value (`memoryStore`) would not satisfy the interface because the
methods have pointer receivers. The rule: if any method has a pointer receiver,
only `*T` satisfies the interface, not `T`.

**`PrefixStore` delegates everything.** All three methods simply prepend the
prefix and call `inner`. The wrapped error from `inner.Get` already satisfies
`errors.Is(err, ErrNotFound)` — `PrefixStore` does not need to re-wrap it.

## Interface implementation check at compile time

A useful pattern: add this to your file during development to get a compile error
(not a runtime panic) if the type doesn't satisfy the interface:

```go
var _ Store = (*memoryStore)(nil)
var _ Store = (*prefixStore)(nil)
```

These are blank identifier assignments — no runtime cost. The compiler type-checks
the right-hand side against `Store` and fails fast if a method is missing.

## The `%w` vs `%v` distinction — production impact

```go
// WRONG — breaks errors.Is for every caller
return "", fmt.Errorf("Get %q: %v", key, ErrNotFound)
// → errors.Is(err, ErrNotFound) == false
// → HTTP middleware returns 500 instead of 404

// CORRECT — errors.Is walks the chain
return "", fmt.Errorf("Get %q: %w", key, ErrNotFound)
// → errors.Is(err, ErrNotFound) == true regardless of how many %w wraps follow
```

In a real service you also want `errors.As` when the sentinel is a struct type
with fields (e.g. `*NotFoundError{Resource: "user", ID: id}`) — `errors.As`
extracts the first value in the chain matching the target type, letting you read
the structured fields without string-parsing.
