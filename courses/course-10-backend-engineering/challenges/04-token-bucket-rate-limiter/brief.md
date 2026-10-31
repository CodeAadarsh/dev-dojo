# Token Bucket Rate Limiter

The payment service is getting hammered. During a flash sale, request volume spiked 40x and the service fell over — no rate limiting, no back-pressure. You open the on-call ticket: *"Any customer can fire unlimited requests; a single aggressive client can take down the whole service."*

Your task: implement a production-grade **token-bucket rate limiter** in Python.

## Why token bucket?

A naive counter (`if count > N: reject`) resets on a fixed clock boundary, which means a client can double-burst straddling the reset (N requests just before midnight, N just after). Token bucket solves this by modeling the rate as a leaky bucket:

- The bucket starts full (capacity = max burst size).
- Tokens are added continuously at `refill_rate` per second, up to `capacity`.
- Each allowed request consumes one token. No token → reject (HTTP 429).

This gives you **burst tolerance** (a sudden legitimate spike can use accumulated tokens) and a **sustainable steady-state rate** (refill_rate requests/second long-term).

## Mission

Open `$HOME/.kube-dojo-work/04-token-bucket-rate-limiter/ratelimiter.py` and implement `TokenBucketLimiter.allow()`.

The verifier will accept your work only when **all four pytest cases pass**:

1. **`test_initial_burst`** — a fresh limiter with `capacity=5` must allow the first 5 consecutive calls.
2. **`test_exhausted_bucket_denies`** — after draining `capacity=3` tokens with `refill_rate=0.0`, the next call must return `False`.
3. **`test_refill_over_time`** — `capacity=1, refill_rate=20.0` (1 token per 50 ms): drain the bucket, sleep 120 ms, and the next call must be allowed again.
4. **`test_thread_safety`** — 30 concurrent threads against `capacity=10, refill_rate=0.0` must yield **exactly 10** allowed (not 11 or 12 from a race condition).

## Setup

```bash
bash courses/course-10-backend-engineering/challenges/04-token-bucket-rate-limiter/setup.sh
cd $HOME/.kube-dojo-work/04-token-bucket-rate-limiter
python3 -m venv .venv && source .venv/bin/activate && pip install pytest
```

## Rules

- Edit only `ratelimiter.py`. Do not modify `test_ratelimiter.py`.
- `allow()` must return `True` (allowed) or `False` (denied / would be HTTP 429).
- `allow()` must be thread-safe.

When all tests are green, run the verifier:

```bash
bash courses/course-10-backend-engineering/challenges/04-token-bucket-rate-limiter/verify.sh
```
