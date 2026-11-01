#!/usr/bin/env bash
# Plants the "Go Fundamentals" starter module into the work directory.
# Idempotent — re-running overwrites source files but never deletes the module cache.
set -euo pipefail

SLUG="01-go-basics"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── go.mod ───────────────────────────────────────────────────────────────────
cat > "$WORK/go.mod" << 'EOF'
module dojo/basics

go 1.22
EOF

# ── basics.go (stub) ─────────────────────────────────────────────────────────
cat > "$WORK/basics.go" << 'EOF'
package basics

// WordFreq returns a map of word -> count for the input string.
// Words are split on whitespace; counts are case-insensitive ("Go" and "go"
// both count as "go"). An empty string returns an empty (non-nil) map.
func WordFreq(s string) map[string]int {
	panic("not implemented")
}

// Map applies f to every element of in and returns the results in order.
// An empty input must return a non-nil empty slice, not nil.
func Map[T, U any](in []T, f func(T) U) []U {
	panic("not implemented")
}

// Filter returns the elements of in for which keep returns true.
// An empty result must be a non-nil empty slice, not nil.
func Filter[T any](in []T, keep func(T) bool) []T {
	panic("not implemented")
}
EOF

# ── basics_test.go (visible smoke tests) ─────────────────────────────────────
cat > "$WORK/basics_test.go" << 'EOF'
package basics_test

import (
	"testing"

	basics "dojo/basics"
)

func TestWordFreq_basic(t *testing.T) {
	got := basics.WordFreq("go is great and go runs everywhere")
	if got["go"] != 2 {
		t.Fatalf("want go=2, got %d", got["go"])
	}
	if got["great"] != 1 {
		t.Fatalf("want great=1, got %d", got["great"])
	}
}

func TestMap_double(t *testing.T) {
	out := basics.Map([]int{1, 2, 3}, func(n int) int { return n * 2 })
	if len(out) != 3 || out[0] != 2 || out[1] != 4 || out[2] != 6 {
		t.Fatalf("Map double: got %v", out)
	}
}

func TestFilter_evens(t *testing.T) {
	out := basics.Filter([]int{1, 2, 3, 4, 5}, func(n int) bool { return n%2 == 0 })
	if len(out) != 2 || out[0] != 2 || out[1] != 4 {
		t.Fatalf("Filter evens: got %v", out)
	}
}
EOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement WordFreq, Map[T,U], and Filter[T] in basics.go"
echo "                 so ALL tests in the harness pass (visible + hidden)."
echo
echo "Run local tests: cd $WORK && go test ./..."
echo "Verify + flag  : bash courses/course-22-go-cloud-native/challenges/01-go-basics/verify.sh"
