# Solution — Steady-State Hypothesis

Two functions to implement in `steady_state.py`. The design is deliberate: `check_steady_state` is the primitive; `run_chaos_experiment` composes it.

```python
# steady_state.py — complete implementation

class SteadyStateError(Exception):
    def __init__(self, measured_rate: float, threshold: float, message: str = ""):
        self.measured_rate = measured_rate
        self.threshold = threshold
        super().__init__(
            message or f"SLI {measured_rate:.4f} < threshold {threshold:.4f}"
        )


def check_steady_state(simulator, sli_threshold: float = 0.99, n_samples: int = 1000) -> float:
    rate = simulator.measure_success_rate(n_samples)
    if rate < sli_threshold:
        raise SteadyStateError(rate, sli_threshold)
    return rate


def run_chaos_experiment(
    simulator,
    fault_duration_calls: int = 1000,
    sli_threshold: float = 0.99,
    n_samples: int = 1000,
) -> dict:
    result = {
        'pre_rate': None,
        'during_rate': None,
        'hypothesis_held': False,
        'aborted': False,
    }

    # Step 1: verify pre-condition — abort without touching the system if broken
    try:
        result['pre_rate'] = check_steady_state(simulator, sli_threshold, n_samples)
    except SteadyStateError as e:
        result['pre_rate'] = e.measured_rate
        result['aborted'] = True
        return result

    # Step 2 & 3: inject fault, measure, always remove
    simulator.inject_fault()
    try:
        during_rate = simulator.measure_success_rate(fault_duration_calls)
        result['during_rate'] = during_rate
        result['hypothesis_held'] = during_rate >= sli_threshold
    finally:
        simulator.remove_fault()   # runs even if measure_success_rate raises

    return result
```

## Why each decision is correct

**`SteadyStateError` carries the rate.** When `run_chaos_experiment` catches it, the rate is already known from the measurement — no second measurement needed. This keeps the interface consistent: every path sets `pre_rate`.

**Abort before inject.** If the pre-condition fails, the system is *already* in a bad state. Injecting a fault on top of an already-degraded system produces meaningless data. More importantly, it can make a production incident worse: chaos tooling that ignores a failed pre-condition is dangerous.

**`try/finally` around inject/measure.** The fault is a stateful change to the `simulator`. If the measurement code raises for any reason, `finally` guarantees `remove_fault()` runs. Without this, faults left active after a failed experiment silently corrupt all subsequent measurements.

**`hypothesis_held` is a boolean, not a pass/fail judgement.** `False` is a useful result — it means your chaos experiment found a real weakness. The correct response is not to mark the experiment as "failed" but to create a ticket and improve the system. The confusion between "experiment outcome" and "system health verdict" is a common antipattern in chaos tooling.

## The steady-state hypothesis in practice

The pattern maps directly to Chaos Mesh / Litmus / Gremlin experiment definitions:

```
Steady State:  error_rate(5m) < 0.5%         # = success_rate >= 99.5%
Hypothesis:    this holds during a pod kill
Experiment:    kill one replica of service X
Expected:      the SLI recovers within 30s
```

If the SLI doesn't recover within the observation window, the hypothesis is violated — you've discovered that your redundancy or circuit-breaker config is insufficient for a single pod failure.
