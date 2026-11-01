# Steady-State Hypothesis

Your team ran a chaos experiment last quarter: you killed a pod, waited a bit, restarted it, and declared success. The post-incident review asked one uncomfortable question: *"What exactly were you measuring? What would have had to be true for you to call it a failure?"*

Nobody had a good answer. The experiment proved nothing, because it had no hypothesis.

Chaos Engineering without a steady-state hypothesis is just breaking things. The hypothesis is what separates a principled experiment from chaos for its own sake. It takes the form: "Under normal conditions, `<SLI>` holds at `<threshold>`. After we inject `<fault>`, the SLI still holds." If the SLI stays within threshold during the fault: hypothesis confirmed, resilience validated. If it breaches: hypothesis violated, you found a weakness before a customer did.

## What's planted

`setup.sh` plants a work directory at `~/.kube-dojo-work/05-steady-state-hypothesis/`:

```
05-steady-state-hypothesis/
├── simulator.py              # deterministic service simulator — read this first
├── steady_state.py           # your implementation target (stubs with NotImplementedError)
└── tests/
    └── test_visible.py       # visible harness — run this while you develop
```

`simulator.py` provides `ServiceSimulator` — a deterministic in-process model of a service with a configurable base success rate and a toggleable fault that drops the success rate. Read it before implementing.

## Mission

Implement two functions in `steady_state.py`:

### `check_steady_state(simulator, sli_threshold, n_samples)`

Measure the simulator's success rate over `n_samples` calls. Return the measured rate. Raise `SteadyStateError` (already defined in the stub) if the rate is below `sli_threshold`.

`SteadyStateError` carries the measured rate and the threshold — the caller needs both.

### `run_chaos_experiment(simulator, fault_duration_calls, sli_threshold, n_samples)`

Orchestrate the full experiment lifecycle:

1. **Verify pre-condition**: measure success rate (`n_samples` calls). If below threshold, set `result['aborted'] = True` and return — do NOT inject the fault. A broken baseline invalidates the experiment.
2. **Inject fault**: call `simulator.inject_fault()`.
3. **Measure under fault**: `fault_duration_calls` calls via `simulator.measure_success_rate()`.
4. **Remove fault**: call `simulator.remove_fault()` (always, even if step 3 raises).
5. **Return** a dict with keys: `pre_rate`, `during_rate`, `hypothesis_held`, `aborted`.

`hypothesis_held` is `True` when `during_rate >= sli_threshold`. It does not mean the experiment was a success — a violated hypothesis is a *useful* result.

## Develop with the visible tests

```bash
cd ~/.kube-dojo-work/05-steady-state-hypothesis
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
pytest tests/test_visible.py -v
```

## Verify

```bash
bash courses/course-28-chaos-engineering/challenges/05-steady-state-hypothesis/verify.sh
```

The verifier runs a hidden pytest that checks your implementation across multiple threshold and fault configurations. All tests green → flag printed.

## Prerequisites

python3 + pytest
