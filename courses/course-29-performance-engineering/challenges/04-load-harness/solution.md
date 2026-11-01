# Solution: Build a Load Harness

## The core pattern

A load harness is a producer (main thread) feeding work to a bounded pool of consumers (worker threads). The Semaphore is the capacity token: you must hold one to be in-flight, and you release it when done.

### Approach A — manual threading with a Semaphore

```python
import time
import threading
from dataclasses import dataclass, field
from typing import Callable, List


@dataclass
class HarnessResult:
    total_requests: int = 0
    latencies_ms: List[float] = field(default_factory=list)
    elapsed_s: float = 0.0

    @property
    def p95_ms(self) -> float:
        if not self.latencies_ms:
            return 0.0
        s = sorted(self.latencies_ms)
        idx = max(0, int(0.95 * len(s)) - 1)
        return s[idx]

    @property
    def throughput_rps(self) -> float:
        if self.elapsed_s <= 0:
            return 0.0
        return self.total_requests / self.elapsed_s


def run_load(target_fn: Callable, n_requests: int, concurrency: int) -> HarnessResult:
    result = HarnessResult()
    lock = threading.Lock()
    sem = threading.Semaphore(concurrency)
    t_start = time.perf_counter()
    threads = []

    def task():
        t0 = time.perf_counter()
        target_fn()
        ms = (time.perf_counter() - t0) * 1000.0
        with lock:
            result.total_requests += 1
            result.latencies_ms.append(ms)
        sem.release()   # return the capacity token

    for _ in range(n_requests):
        sem.acquire()   # blocks when concurrency threads are already in flight
        t = threading.Thread(target=task)
        t.start()
        threads.append(t)

    for t in threads:
        t.join()

    result.elapsed_s = time.perf_counter() - t_start
    return result
```

**Why `sem.acquire()` before `t.start()`?** The Semaphore count represents available concurrency slots. The main thread acquires one slot before spawning the thread; the thread releases it when `target_fn()` returns. At any moment, `concurrency - sem._value` equals the number of in-flight requests.

**Why a Lock on `result`?** Multiple threads write to `total_requests` and `latencies_ms` concurrently. Without a lock, you get race conditions — torn reads/writes on the list. A Lock ensures mutations are atomic.

**Why `perf_counter()` not `time()`?** `time.perf_counter()` is monotonic and has nanosecond resolution. `time.time()` can jump backwards on clock adjustments (NTP sync mid-run). For latency measurement always use `perf_counter`.

### Approach B — ThreadPoolExecutor (idiomatic, fewer lines)

```python
from concurrent.futures import ThreadPoolExecutor
import time, threading

def run_load(target_fn, n_requests, concurrency):
    result = HarnessResult()
    lock = threading.Lock()
    t_start = time.perf_counter()

    def task(_):
        t0 = time.perf_counter()
        target_fn()
        ms = (time.perf_counter() - t0) * 1000.0
        with lock:
            result.total_requests += 1
            result.latencies_ms.append(ms)

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        list(pool.map(task, range(n_requests)))

    result.elapsed_s = time.perf_counter() - t_start
    return result
```

`ThreadPoolExecutor(max_workers=concurrency)` keeps at most `concurrency` threads active. `pool.map` submits all `n_requests` tasks and blocks until they all complete. The `list(...)` call is required — `map` is lazy (a generator) and will not run tasks without consuming the iterator.

## p95 computation explained

```
sorted_latencies = [10, 12, 14, 15, 18, 22, 30, 50, 80, 120]  # 10 values
p95 index         = int(0.95 * 10) - 1 = 9 - 1 = 8
p95               = sorted_latencies[8] = 80 ms
```

The formula `int(0.95 * n) - 1` gives the nearest-rank p95 (rounds down to the index of the 95th-percentile value). For n=100 this is index 94 — the 95th smallest. `max(0, ...)` prevents negative indices for tiny `n`.

## What this tells you about production tools

Every load tool is this loop:
- **Closed model** (constant concurrency, like this harness): `n` workers each complete a request, then immediately send the next. Max in-flight = `n`.
- **Open model** (constant arrival rate, like k6's `arrivalRate`): arrivals are Poisson-distributed regardless of how long requests take. The concurrency floats; under overload it grows without bound.

Coordinated omission (Gil Tene's term): a closed-model harness *stops* issuing requests while the previous ones are slow. Under a sudden spike of 10-second timeouts, your harness reports "10s latency" but hides that you also missed hundreds of requests that *would have arrived* during those 10s. Open-model tools expose this; closed-model tools hide it. Knowing which your tool is changes how you interpret p99.
