#!/usr/bin/env bash
# Plants the "Bounded Worker Pool" starter module into the work directory.
# Idempotent — re-running overwrites source files but never touches go cache.
set -euo pipefail

SLUG="02-concurrency-worker-pool"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── go.mod ───────────────────────────────────────────────────────────────────
cat > "$WORK/go.mod" << 'EOF'
module dojo/pool

go 1.22
EOF

# ── pool.go (stub) ───────────────────────────────────────────────────────────
cat > "$WORK/pool.go" << 'EOF'
package pool

// Job is a unit of work.
type Job struct {
	ID    int
	Input int
}

// Result holds the outcome of processing a Job.
type Result struct {
	JobID  int
	Output int
}

// WorkerPool starts exactly n worker goroutines that pull from jobs,
// apply transform to each Job.Input, and push Result values to results.
//
// WorkerPool BLOCKS until all jobs have been processed. It closes results
// before returning so callers can range over it safely.
//
// Constraints:
//   - Exactly n goroutines must be started (no more, no less).
//   - Every Job sent on jobs must produce exactly one Result on results.
//   - The implementation must be race-free (go test -race ./... must pass).
func WorkerPool(n int, jobs <-chan Job, results chan<- Result, transform func(int) int) {
	panic("not implemented")
}
EOF

# ── pool_test.go (visible smoke test) ────────────────────────────────────────
cat > "$WORK/pool_test.go" << 'EOF'
package pool_test

import (
	"testing"

	pool "dojo/pool"
)

func TestWorkerPool_basic(t *testing.T) {
	jobs := make(chan pool.Job, 5)
	results := make(chan pool.Result, 5)

	for i := 1; i <= 5; i++ {
		jobs <- pool.Job{ID: i, Input: i}
	}
	close(jobs)

	pool.WorkerPool(3, jobs, results, func(n int) int { return n * n })

	var sum int
	for r := range results {
		sum += r.Output
	}
	// 1²+2²+3²+4²+5² = 1+4+9+16+25 = 55
	if sum != 55 {
		t.Fatalf("want sum=55, got %d", sum)
	}
}
EOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement WorkerPool in pool.go"
echo "                 — exactly n goroutines, all jobs processed exactly once,"
echo "                   results channel closed, race-free."
echo
echo "Run local tests: cd $WORK && go test ./..."
echo "Race check     : cd $WORK && go test -race ./..."
echo "Verify + flag  : bash courses/course-22-go-cloud-native/challenges/02-concurrency-worker-pool/verify.sh"
