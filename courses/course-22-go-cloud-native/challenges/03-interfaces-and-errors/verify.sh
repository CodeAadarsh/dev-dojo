#!/usr/bin/env bash
# Verifier for "Interfaces and Sentinel Errors".
# Ships a hidden test file, runs go test ./..., prints the flag on all-pass.
set -uo pipefail

SLUG="03-interfaces-and-errors"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{interfaces_and_sentinel_errors}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]        || fail "work directory missing — run setup.sh first"
[ -f "$WORK/go.mod" ]  || fail "go.mod missing — run setup.sh first"
[ -f "$WORK/store.go" ] || fail "store.go missing — run setup.sh first"

# ── ship hidden test file ────────────────────────────────────────────────────
cat > "$WORK/store_hidden_test.go" << 'GOEOF'
package store_test

import (
	"errors"
	"fmt"
	"testing"

	store "dojo/store"
)

func TestMemoryStore_delete(t *testing.T) {
	s := store.NewMemoryStore()
	s.Set("x", "y")
	s.Delete("x")
	_, err := s.Get("x")
	if !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("after Delete: want ErrNotFound, got %v", err)
	}
}

func TestMemoryStore_deleteAbsent(t *testing.T) {
	s := store.NewMemoryStore()
	// Must not panic on a key that was never set.
	s.Delete("nonexistent")
}

func TestMemoryStore_overwrite(t *testing.T) {
	s := store.NewMemoryStore()
	s.Set("k", "first")
	s.Set("k", "second")
	got, err := s.Get("k")
	if err != nil || got != "second" {
		t.Fatalf("overwrite: got (%q, %v), want (\"second\", nil)", got, err)
	}
}

func TestPrefixStore_physicalKey(t *testing.T) {
	inner := store.NewMemoryStore()
	p := store.NewPrefixStore("ns:", inner)
	p.Set("key", "value")
	// inner must have stored the key under "ns:key", not "key"
	got, err := inner.Get("ns:key")
	if err != nil || got != "value" {
		t.Fatalf("PrefixStore.Set must store under prefix+key in inner; got (%q, %v)", got, err)
	}
}

func TestPrefixStore_notFoundWrapped(t *testing.T) {
	inner := store.NewMemoryStore()
	p := store.NewPrefixStore("pfx:", inner)
	_, err := p.Get("absent")
	if !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("PrefixStore.Get miss: errors.Is(err, ErrNotFound) must be true, got %v", err)
	}
}

func TestPrefixStore_isolatesNamespaces(t *testing.T) {
	inner := store.NewMemoryStore()
	p1 := store.NewPrefixStore("a:", inner)
	p2 := store.NewPrefixStore("b:", inner)
	p1.Set("x", "from-a")
	p2.Set("x", "from-b")
	v1, err1 := p1.Get("x")
	v2, err2 := p2.Get("x")
	if err1 != nil || v1 != "from-a" {
		t.Fatalf("p1.Get(x): got (%q, %v), want (\"from-a\", nil)", v1, err1)
	}
	if err2 != nil || v2 != "from-b" {
		t.Fatalf("p2.Get(x): got (%q, %v), want (\"from-b\", nil)", v2, err2)
	}
}

func TestPrefixStore_delete(t *testing.T) {
	inner := store.NewMemoryStore()
	p := store.NewPrefixStore("pre:", inner)
	p.Set("doc", "val")
	p.Delete("doc")
	_, err := p.Get("doc")
	if !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("PrefixStore.Delete: after delete, Get must return ErrNotFound, got %v", err)
	}
}

func TestErrorWrapping_survivesAdditionalWrap(t *testing.T) {
	s := store.NewMemoryStore()
	_, err := s.Get("missing")
	// Simulate what the HTTP middleware does: adds context before checking.
	wrapped := fmt.Errorf("lookup request failed: %w", err)
	if !errors.Is(wrapped, store.ErrNotFound) {
		t.Fatalf("errors.Is through additional fmt.Errorf wrap failed; wrapped=%v", wrapped)
	}
}

func TestPolymorphism(t *testing.T) {
	// Both implementations must satisfy the Store interface and be
	// usable interchangeably through the interface type.
	stores := []store.Store{
		store.NewMemoryStore(),
		store.NewPrefixStore("t:", store.NewMemoryStore()),
	}
	for i, s := range stores {
		s.Set("ping", "pong")
		got, err := s.Get("ping")
		if err != nil || got != "pong" {
			t.Fatalf("store[%d] polymorphic Get: got (%q, %v)", i, got, err)
		}
	}
}
GOEOF

cd "$WORK"
echo "Running go test ./... (visible + hidden tests)..."
echo
if go test ./... 2>&1; then
	echo
	echo "All tests passed. Submit this flag in the platform:"
	echo
	echo "    $FLAG"
else
	fail "test suite has failures — fix your implementation and retry"
fi
