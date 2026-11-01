# Solution — Automated GameDay Runner

One function to implement. The lifecycle is sequential: baseline → inject → monitor loop → rollback → (optionally) after-baseline.

```python
# gameday.py — complete implementation
from typing import Optional


class ExperimentReport:
    def __init__(self):
        self.steady_state_before: Optional[float] = None
        self.steady_state_after: Optional[float] = None
        self.fault_period_slo: Optional[float] = None
        self.aborted: bool = False
        self.abort_reason: Optional[str] = None

    def to_dict(self) -> dict:
        return {
            'steady_state_before': self.steady_state_before,
            'steady_state_after': self.steady_state_after,
            'fault_period_slo': self.fault_period_slo,
            'aborted': self.aborted,
            'abort_reason': self.abort_reason,
        }


def run_gameday(
    system,
    slo_threshold: float = 0.95,
    n_baseline: int = 500,
    n_monitor: int = 200,
    experiment_label: str = 'gameday-1',
) -> ExperimentReport:
    report = ExperimentReport()

    # Step 1: baseline steady state (before touching anything)
    report.steady_state_before = system.measure_slo(n_baseline)

    # Step 2: inject the fault
    system.inject_fault(experiment_label)

    # Step 3: monitor SLO — 3 samples during fault window
    samples = []
    for _ in range(3):
        sample = system.measure_slo(n_monitor)
        samples.append(sample)
        if sample < slo_threshold:
            # Step 4a: SLO breach — abort and rollback immediately
            system.rollback(experiment_label)
            report.aborted = True
            report.abort_reason = 'slo_breach'
            report.fault_period_slo = min(samples)
            return report

    # Step 4b: no breach — remove fault cleanly
    system.rollback(experiment_label)

    # Step 5: after-state (only when not aborted)
    report.steady_state_after = system.measure_slo(n_baseline)

    # Step 6: worst-case fault-period SLO
    report.fault_period_slo = min(samples)

    return report
```

## Why each decision is correct

**`steady_state_before` before any mutation.** You need to know the system was healthy at experiment time — not just assume it. If you start an experiment when the system is already degraded, your "fault" results are confounded with a pre-existing incident. Production chaos tooling (Chaos Toolkit, Gremlin) refuses to start if the pre-condition probe fails.

**3 monitoring samples, not 1.** A single sample is noisy. Three samples catch a fault that the system partially recovers from — if sample 1 is borderline but samples 2–3 breach, a single-sample check would miss the breach. Using `min()` over all samples gives the worst case rather than the average, which is the right metric for an SLO (SLOs are about tail behavior, not averages).

**`rollback` on breach, not in a finally.** Unlike a simple try/finally pattern, this design calls `rollback` *at the decision point* — immediately on breach. A `finally` would call `rollback` after all monitoring samples, even after a breach, delaying recovery by up to 2 more monitoring windows. In a real system, that extra latency matters: a 200ms-per-request service at `n_monitor=200` costs 40 seconds per sample.

**`steady_state_after` is None on abort.** When you abort because the SLO breached, the system is in a degraded state at the moment of rollback. Measuring the SLO at that instant gives a misleading low value — the system hasn't had time to recover. Omitting `steady_state_after` on abort is an explicit signal to the report consumer: "we aborted, recovery state unknown."

**Event log as audit trail.** `system.events` records `('fault_injected', label)` and `('rollback', label)` in order. This is the same pattern that Kubernetes admission webhooks, Chaos Mesh experiment controllers, and distributed tracing systems use: every state change is an immutable append-only record. The verifier checks this log to confirm that rollback happened and that it happened *after* inject — ordering matters.

## Extending to a real cluster

Map the `MockSystem` API to real kubectl commands:

```python
def inject_fault(self, label):
    subprocess.run(['kubectl', '-n', 'dojo-chaos', 'scale', 'deploy/backend', '--replicas=0'])
    self.events.append(('fault_injected', label))

def rollback(self, label):
    subprocess.run(['kubectl', '-n', 'dojo-chaos', 'scale', 'deploy/backend', '--replicas=2'])
    self.events.append(('rollback', label))

def measure_slo(self, n):
    # query your Prometheus /api/v1/query for error_rate over the last window
    ...
```

The runner logic is identical — only the I/O layer changes. That's why building the logic against a deterministic in-process model first is the right approach.
