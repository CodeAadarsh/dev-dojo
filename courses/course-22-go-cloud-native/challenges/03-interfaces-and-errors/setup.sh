#!/usr/bin/env bash
# Plants the "Interfaces and Sentinel Errors" starter module.
# Idempotent — re-running overwrites source files, never touches go cache.
set -euo pipefail

SLUG="03-interfaces-and-errors"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── go.mod ───────────────────────────────────────────────────────────────────
cat > "$WORK/go.mod" << 'EOF'
module dojo/store

go 1.22
EOF

# ── store.go (stub) ──────────────────────────────────────────────────────────
cat > "$WORK/store.go" << 'EOF'
package store

import "errors"

// ErrNotFound is the sentinel returned (possibly wrapped) when a key is absent.
// Use fmt.Errorf("...: %w", ErrNotFound) so callers can check with errors.Is.
var ErrNotFound = errors.New("not found")

// Store is a simple key-value interface.
type Store interface {
	// Set stores value under key, replacing any existing entry.
	Set(key, value string)
	// Get returns the value for key.
	// On a miss, it returns ("", err) where errors.Is(err, ErrNotFound) is true.
	Get(key string) (string, error)
	// Delete removes key. No-op if key is absent.
	Delete(key string)
}

// NewMemoryStore returns an in-memory Store backed by a plain map.
func NewMemoryStore() Store {
	panic("not implemented")
}

// NewPrefixStore wraps inner, prepending prefix to every key before
// delegating to inner. It does not own any storage of its own.
func NewPrefixStore(prefix string, inner Store) Store {
	panic("not implemented")
}
EOF

# ── store_test.go (visible smoke tests) ──────────────────────────────────────
cat > "$WORK/store_test.go" << 'EOF'
package store_test

import (
	"errors"
	"testing"

	store "dojo/store"
)

func TestMemoryStore_setAndGet(t *testing.T) {
	s := store.NewMemoryStore()
	s.Set("k", "v")
	got, err := s.Get("k")
	if err != nil || got != "v" {
		t.Fatalf("Get: got (%q, %v), want (\"v\", nil)", got, err)
	}
}

func TestMemoryStore_notFound(t *testing.T) {
	s := store.NewMemoryStore()
	_, err := s.Get("missing")
	if !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("want errors.Is(err, ErrNotFound) == true, got err=%v", err)
	}
}

func TestPrefixStore_getAndSet(t *testing.T) {
	inner := store.NewMemoryStore()
	p := store.NewPrefixStore("ns:", inner)
	p.Set("doc", "hello")
	got, err := p.Get("doc")
	if err != nil || got != "hello" {
		t.Fatalf("PrefixStore.Get: got (%q, %v), want (\"hello\", nil)", got, err)
	}
}
EOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement NewMemoryStore and NewPrefixStore in store.go"
echo "                 — proper error wrapping (%w) so errors.Is(err, ErrNotFound)"
echo "                   works through any additional wrapping layer."
echo
echo "Run local tests: cd $WORK && go test ./..."
echo "Verify + flag  : bash courses/course-22-go-cloud-native/challenges/03-interfaces-and-errors/verify.sh"
