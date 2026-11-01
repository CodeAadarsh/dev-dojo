# Automated GameDay Runner

Your team ran its first structured chaos experiment last sprint. The hypothesis was defined, the SLI was measurable, and the result was clear. One person ran it manually: they scaled a Deployment, watched Grafana for 10 minutes, and scaled it back. The experiment report was a Slack message.

This quarter's GameDay is three experiments across five services, coordinated between two teams. That Slack-message approach doesn't scale. Someone will forget to roll back. Someone will run the experiment while the baseline is already degraded. Someone will declare success because "it looked okay" without actually checking the SLO. And nobody will have a consistent report format to compare experiments week over week.

Automated experiment runners solve all of this: they record steady state before touching anything, enforce abort conditions, guarantee rollback via cleanup hooks, and emit a structured report. Tools like Chaos Toolkit, Gremlin, and the Kubernetes-native Chaos Mesh operator all follow this lifecycle.

## What's planted

`setup.sh` plants a work directory at `~/.kube-dojo-work/06-automated-gameday/`:

```
06-automated-gameday/
├── system.py               # mock system with fault injection and SLO measurement
├── gameday.py              # your implementation target
└── tests/
    └── test_visible.py     # visible harness — run while developing
```

`system.py` provides `MockSystem` — a deterministic in-process system model. Read it: it exposes `request()`, `inject_fault(label)`, `rollback(label)`, `measure_slo(n)`, and an `events` list that records every fault injection and rollback for audit.

## Mission

Implement `run_gameday` in `gameday.py`. It receives a `MockSystem` and orchestrates the full experiment lifecycle:

### The lifecycle

| Step | Action | Notes |
|------|--------|-------|
| 1 | Record `steady_state_before` | `system.measure_slo(n_baseline)` |
| 2 | Inject fault | `system.inject_fault(experiment_label)` |
| 3 | Monitor SLO (3 samples) | `system.measure_slo(n_monitor)` × 3 |
| 4 | If any sample < `slo_threshold` | Call `system.rollback(label)`, set `report.aborted=True`, `report.abort_reason='slo_breach'`, **return immediately** |
| 5 | If no breach | Call `system.rollback(label)` |
| 6 | Record `steady_state_after` | `system.measure_slo(n_baseline)` — **only when not aborted** |
| 7 | Set `report.fault_period_slo` | `min()` of the samples taken in step 3 |
| 8 | Return the report |

### The report

`ExperimentReport` is already defined in the stub. Its `to_dict()` method must return:

```python
{
    'steady_state_before': float,   # baseline SLO before the experiment
    'steady_state_after':  float | None,  # None when aborted
    'fault_period_slo':    float | None,  # min SLO sample during fault
    'aborted':             bool,
    'abort_reason':        str | None,    # 'slo_breach' or None
}
```

## Key correctness requirements

- `steady_state_after` is `None` when aborted — the system is still recovering at abort time; measuring it would produce misleading data.
- `fault_period_slo` uses `min()` over all fault-period samples — the worst case, not the average. Averaging masks brief dips below threshold.
- Rollback is always called: on breach (step 4) and on clean completion (step 5). The fault state of `system` must be `False` after `run_gameday` returns regardless of outcome.
- The `events` list on `system` is your audit trail — the hidden tests inspect it to verify rollback was called in the correct order.

## Develop

```bash
cd ~/.kube-dojo-work/06-automated-gameday
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
pytest tests/test_visible.py -v
```

## Verify

```bash
bash courses/course-28-chaos-engineering/challenges/06-automated-gameday/verify.sh
```

## Prerequisites

python3 + pytest
