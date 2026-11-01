#!/usr/bin/env bash
# Verifier for "Bounded Worker Pool".
# Ships a hidden test file, runs go test -race ./..., and prints the flag
# only when every test passes with zero race reports.
set -uo pipefail

SLUG="02-concurrency-worker-pool"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{bounded_worker_pool_race_free}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]       || fail "work directory missing — run setup.sh first"
[ -f "$WORK/go.mod" ] || fail "go.mod missing — run setup.sh first"
[ -f "$WORK/pool.go" ] || fail "pool.go missing — run setup.sh first"

# ── ship hidden test file ────────────────────────────────────────────────────
cat > "$WORK/pool_hidden_test.go" << 'GOEOF'
package pool_test

import (
	"sort"
	"testing"

	pool "dojo/pool"
)

func TestWorkerPool_100jobs(t *testing.T) {
	const N = 100
	jobs := make(chan pool.Job, N)
	results := make(chan pool.Result, N)
	for i := 1; i <= N; i++ {
		jobs <- pool.Job{ID: i, Input: i}
	}
	close(jobs)

	pool.WorkerPool(8, jobs, results, func(n int) int { return n * 3 })

	var got []int
	for r := range results {
		got = append(got, r.Output)
	}
	if len(got) != N {
		t.Fatalf("want %d results, got %d", N, len(got))
	}
	sort.Ints(got)
	for i, v := range got {
		want := (i + 1) * 3
		if v != want {
			t.Fatalf("result[%d]: got %d, want %d", i, v, want)
		}
	}
}

func TestWorkerPool_exactlyOnce(t *testing.T) {
	const N = 50
	jobs := make(chan pool.Job, N)
	results := make(chan pool.Result, N)
	for i := 0; i < N; i++ {
		jobs <- pool.Job{ID: i, Input: i}
	}
	close(jobs)

	pool.WorkerPool(5, jobs, results, func(n int) int { return n })

	seen := make(map[int]int)
	for r := range results {
		seen[r.JobID]++
	}
	for i := 0; i < N; i++ {
		if seen[i] != 1 {
			t.Fatalf("job %d processed %d times, want exactly 1", i, seen[i])
		}
	}
}

func TestWorkerPool_resultsChannelClosed(t *testing.T) {
	jobs := make(chan pool.Job, 3)
	results := make(chan pool.Result, 3)
	for i := 0; i < 3; i++ {
		jobs <- pool.Job{ID: i, Input: i}
	}
	close(jobs)

	pool.WorkerPool(2, jobs, results, func(n int) int { return n })

	// range hangs forever if results is never closed — the test will timeout
	var count int
	for range results {
		count++
	}
	if count != 3 {
		t.Fatalf("want 3 results from closed channel, got %d", count)
	}
}

func TestWorkerPool_singleWorker(t *testing.T) {
	jobs := make(chan pool.Job, 5)
	results := make(chan pool.Result, 5)
	for i := 1; i <= 5; i++ {
		jobs <- pool.Job{ID: i, Input: i}
	}
	close(jobs)

	pool.WorkerPool(1, jobs, results, func(n int) int { return n + 100 })

	var sum int
	for r := range results {
		sum += r.Output
	}
	// (1+100)+(2+100)+(3+100)+(4+100)+(5+100) = 515
	if sum != 515 {
		t.Fatalf("single worker: want sum=515, got %d", sum)
	}
}

func TestWorkerPool_raceSmoke(t *testing.T) {
	// 16 workers + 200 jobs gives the race detector maximum exposure.
	// If the implementation has any unsynchronized shared state, -race fires here.
	const N = 200
	jobs := make(chan pool.Job, N)
	results := make(chan pool.Result, N)
	for i := 0; i < N; i++ {
		jobs <- pool.Job{ID: i, Input: i}
	}
	close(jobs)

	pool.WorkerPool(16, jobs, results, func(n int) int { return n * n })

	var count int
	for range results {
		count++
	}
	if count != N {
		t.Fatalf("raceSmoke: want %d results, got %d", N, count)
	}
}
GOEOF

cd "$WORK"
echo "Running go test -race ./... (visible + hidden tests)..."
echo
if go test -race ./... 2>&1; then
	echo
	echo "All tests passed with zero race reports. Submit this flag in the platform:"
	echo
	echo "    $FLAG"
else
	fail "test suite has failures or race conditions — fix your implementation and retry"
fi
