#!/usr/bin/env bash
# Plants the token-bucket rate limiter challenge: skeleton + pytest harness.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/04-token-bucket-rate-limiter"
mkdir -p "$WORK"

# --- skeleton: ratelimiter.py ---
cat > "$WORK/ratelimiter.py" << 'PYEOF'
# ratelimiter.py — implement TokenBucketLimiter here
import threading
import time


class TokenBucketLimiter:
    """
    Token-bucket rate limiter.

    capacity    — maximum tokens the bucket can hold (also the initial fill level).
    refill_rate — tokens added per second (continuous, not discrete ticks).
    """

    def __init__(self, capacity: int, refill_rate: float) -> None:
        self.capacity = capacity
        self.refill_rate = refill_rate
        # TODO: initialise your state here

    def allow(self) -> bool:
        """
        Return True if the request is within the rate limit (consume one token).
        Return False if the bucket is empty (request should be rejected / HTTP 429).
        Must be thread-safe.
        """
        # TODO: implement token-bucket logic
        raise NotImplementedError
PYEOF

# --- test harness: test_ratelimiter.py (do not edit) ---
cat > "$WORK/test_ratelimiter.py" << 'PYEOF'
# test_ratelimiter.py — DO NOT EDIT; this is the verifier harness
import time
import threading
from ratelimiter import TokenBucketLimiter


def test_initial_burst():
    """Bucket at full capacity: first N calls must all be allowed."""
    limiter = TokenBucketLimiter(capacity=5, refill_rate=1.0)
    results = [limiter.allow() for _ in range(5)]
    assert all(results), f"Expected all 5 to be allowed, got: {results}"


def test_exhausted_bucket_denies():
    """After draining capacity, the very next call must be denied."""
    limiter = TokenBucketLimiter(capacity=3, refill_rate=0.0)
    for _ in range(3):
        limiter.allow()
    assert limiter.allow() is False, (
        "Exhausted bucket must deny the next request (return False)"
    )


def test_refill_over_time():
    """Tokens refill continuously; after enough time, allow() must succeed again."""
    # 20 tokens/sec = 1 token per 50 ms; sleep 120 ms guarantees >= 1 token refilled
    limiter = TokenBucketLimiter(capacity=1, refill_rate=20.0)
    assert limiter.allow() is True    # drain the single token
    assert limiter.allow() is False   # bucket is now empty
    time.sleep(0.12)                  # 120 ms >> 50 ms; at least 1 token refilled
    assert limiter.allow() is True, (
        "Bucket should have refilled after 120 ms at refill_rate=20.0 (1 token per 50 ms)"
    )


def test_thread_safety():
    """Concurrent allow() calls must not grant more tokens than capacity."""
    limiter = TokenBucketLimiter(capacity=10, refill_rate=0.0)  # no refill
    results = []
    lock = threading.Lock()

    def probe():
        r = limiter.allow()
        with lock:
            results.append(r)

    threads = [threading.Thread(target=probe) for _ in range(30)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    granted = sum(1 for r in results if r)
    assert granted == 10, (
        f"Expected exactly 10 allowed (capacity=10), got {granted}. "
        "Hint: is allow() protected by a threading.Lock?"
    )
PYEOF

echo
echo "Work directory: $WORK"
echo
echo "Files written:"
echo "  ratelimiter.py      — skeleton; implement TokenBucketLimiter.allow() here"
echo "  test_ratelimiter.py — verifier harness (do not edit)"
echo
echo "Task:"
echo "  Implement TokenBucketLimiter.allow() so the bucket:"
echo "  - Starts full (tokens = capacity)"
echo "  - Refills continuously at refill_rate tokens/second, capped at capacity"
echo "  - Consumes exactly 1 token per allowed request; returns False when empty"
echo "  - Is thread-safe (concurrent calls must not over-grant)"
echo
echo "Prereqs (run inside $WORK):"
echo "  python3 -m venv .venv && source .venv/bin/activate && pip install pytest"
echo
echo "Run tests:"
echo "  cd $WORK && .venv/bin/python -m pytest test_ratelimiter.py -v"
