#!/usr/bin/env bash
# Verifier for "Go Fundamentals: WordFreq + Generics".
# Ships a hidden test file into the work directory, runs go test ./...,
# and prints the flag only when every test passes.
set -uo pipefail

SLUG="01-go-basics"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{go_fundamentals_mastered}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]      || fail "work directory missing — run setup.sh first"
[ -f "$WORK/go.mod" ] || fail "go.mod missing — run setup.sh first"
[ -f "$WORK/basics.go" ] || fail "basics.go missing — run setup.sh first"

# ── ship hidden test file ────────────────────────────────────────────────────
cat > "$WORK/basics_hidden_test.go" << 'GOEOF'
package basics_test

import (
	"strings"
	"testing"

	basics "dojo/basics"
)

func TestWordFreq_caseInsensitive(t *testing.T) {
	got := basics.WordFreq("Go GO go")
	if got["go"] != 3 {
		t.Fatalf("case insensitive: want go=3, got %d", got["go"])
	}
}

func TestWordFreq_empty(t *testing.T) {
	got := basics.WordFreq("")
	if len(got) != 0 {
		t.Fatalf("empty string: want empty map, got %v", got)
	}
}

func TestWordFreq_leadingTrailingSpaces(t *testing.T) {
	got := basics.WordFreq("  hello world hello  ")
	if got["hello"] != 2 {
		t.Fatalf("spaces: want hello=2, got %d", got["hello"])
	}
}

func TestWordFreq_repeated(t *testing.T) {
	got := basics.WordFreq("kubernetes kubernetes kubernetes")
	if got["kubernetes"] != 3 {
		t.Fatalf("repeated: want kubernetes=3, got %d", got["kubernetes"])
	}
}

func TestWordFreq_singleWord(t *testing.T) {
	got := basics.WordFreq("pipeline")
	if got["pipeline"] != 1 {
		t.Fatalf("single word: want pipeline=1, got %d", got["pipeline"])
	}
}

func TestMap_strings(t *testing.T) {
	out := basics.Map([]string{"go", "cloud"}, strings.ToUpper)
	if len(out) != 2 || out[0] != "GO" || out[1] != "CLOUD" {
		t.Fatalf("Map strings ToUpper: got %v", out)
	}
}

func TestMap_empty(t *testing.T) {
	out := basics.Map([]int{}, func(n int) int { return n })
	if len(out) != 0 {
		t.Fatalf("Map empty input: want len=0, got %d", len(out))
	}
}

func TestMap_floats(t *testing.T) {
	out := basics.Map([]float64{2.0, 4.0, 6.0}, func(f float64) float64 { return f / 2 })
	if len(out) != 3 || out[0] != 1.0 || out[1] != 2.0 || out[2] != 3.0 {
		t.Fatalf("Map floats: got %v", out)
	}
}

func TestFilter_noMatch(t *testing.T) {
	out := basics.Filter([]int{1, 3, 5}, func(n int) bool { return n%2 == 0 })
	if len(out) != 0 {
		t.Fatalf("Filter no match: want len=0, got %v", out)
	}
}

func TestFilter_allMatch(t *testing.T) {
	out := basics.Filter([]string{"a", "b", "c"}, func(s string) bool { return true })
	if len(out) != 3 {
		t.Fatalf("Filter all match: want len=3, got %v", out)
	}
}

func TestFilter_empty(t *testing.T) {
	out := basics.Filter([]int{}, func(n int) bool { return true })
	if len(out) != 0 {
		t.Fatalf("Filter empty input: want len=0, got %v", out)
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
