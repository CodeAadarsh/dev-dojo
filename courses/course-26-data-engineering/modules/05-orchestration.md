# Orchestration (Airflow & DAGs)

> **Module 05 · Course 26** — Airflow is the lingua franca of data orchestration. If you have touched a data platform at scale you have debugged a DAG. This module covers how scheduling, backfills, and the executor model actually work — not the UI tour, but the mental model that keeps you out of the 3 a.m. incident at the quarter close.

You already know what a DAG is conceptually. The goal here is to understand why Airflow makes the choices it does (and where those choices bite you) so you can design pipelines that are deterministic, observable, and easy to rerun.

---

## DAGs as Code

Every Airflow pipeline is a Python file in `$AIRFLOW_HOME/dags/`. The scheduler polls that directory, imports every `.py` file, and builds the DAG object graph. The import happens *repeatedly* (the scheduler re-scans constantly), which means:

- **Top-level code runs on every scan.** A database connection or an HTTP call at module scope will be made hundreds of times per day, silently. Keep heavy I/O inside operator `execute()` hooks, not at import time.
- **DAG ID must be globally unique.** Two files that produce a DAG with the same `dag_id` cause unpredictable behavior — the scheduler silently picks one.

```python
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator

with DAG(
    dag_id="ingest_events",
    schedule_interval="0 3 * * *",          # every day at 03:00 UTC
    start_date=datetime(2024, 1, 1),
    catchup=False,                           # IMPORTANT — see Backfills section
    default_args={
        "retries": 2,
        "retry_delay": timedelta(minutes=5),
        "depends_on_past": False,
    },
    tags=["ingest", "events"],
) as dag:

    def extract(**context):
        # context["ds"] is the logical date — always use this, not datetime.now()
        logical_date = context["ds"]
        print(f"Extracting for {logical_date}")

    def load(**context):
        logical_date = context["ds"]
        print(f"Loading for {logical_date}")

    t_extract = PythonOperator(task_id="extract", python_callable=extract)
    t_load    = PythonOperator(task_id="load",    python_callable=load)

    t_extract >> t_load
```

### The logical date vs wall-clock time

This is the single most important concept in Airflow scheduling, and the source of more bugs than everything else combined:

> **`ds` (data stamp / logical date) is the start of the *interval* being processed, not the time the task runs.**

For a daily DAG with `schedule_interval="0 3 * * *"` and `start_date=2024-01-01`:

```
Interval            logical date (ds)    when it actually runs
2024-01-01 00:00 →  2024-01-01           2024-01-02 03:00 UTC
2024-01-02 00:00 →  2024-01-02           2024-01-03 03:00 UTC
```

The run for "2024-01-01 data" executes on January 2nd at 03:00. This is intentional: Airflow models it as "the interval ending at schedule_interval tick, triggered at the end of the interval." If you write `datetime.now()` inside a task instead of using `context["ds"]`, **your pipeline becomes non-idempotent** and backfills produce garbage.

---

## Operators, Tasks, and Dependencies

An **operator** is a template for a unit of work. A **task** is an instance of an operator within a DAG. When Airflow runs a DAG, it schedules individual tasks — each is a row in the `task_instance` table.

### Built-in operators worth knowing

| Operator | Use | Gotcha |
|----------|-----|--------|
| `PythonOperator` | Call a Python function | Heavy computation blocks a worker slot; use it for I/O-bound work or offload to a cluster |
| `BashOperator` | Run a shell command | Script exit codes propagate; `set -e` is not implicit — a failing subcommand in a pipeline doesn't fail the task unless you add `set -e` |
| `BranchPythonOperator` | Return a task_id to route to | Downstream tasks on the unchosen branch are `skipped`, not failed; the downstream of a skipped task is also skipped unless you add `trigger_rule=TriggerRule.NONE_SKIPPED` |
| `ShortCircuitOperator` | Skip all downstream if returns `False` | Entire downstream subtree is marked `skipped` |
| `DummyOperator` / `EmptyOperator` | Sync point, visual grouping | No-op; used to fan-in before a final task |

### Expressing dependencies

```python
# simple chain
a >> b >> c

# fan-out
a >> [b, c]

# fan-in
[b, c] >> d

# complex: a → b, a → c, b+c → d
a >> [b, c]
[b, c] >> d

# depends_on_past: this run's task waits for the previous DAG run's same task
PythonOperator(task_id="check", depends_on_past=True, python_callable=check)
```

`depends_on_past=True` is a strong constraint: if yesterday's `check` failed or was skipped, today's `check` is blocked. It's the right tool for strict sequential watermarks, but it means a single failure cascades into all future runs.

---

## Scheduling & Intervals

Airflow accepts three forms for `schedule_interval`:

```python
schedule_interval="@daily"         # preset: once per day at 00:00 UTC
schedule_interval="0 3 * * *"      # cron: 03:00 UTC every day
schedule_interval=timedelta(hours=6)  # timedelta
schedule_interval=None             # manually triggered only
```

**Cron vs timedelta:** cron expressions are anchored to the clock (run at 03:00 every day regardless of task duration). `timedelta` schedules relative to the previous run's `execution_date` — a 6-hour interval on a task that runs for 2 hours doesn't trigger a "drift" correction; the next logical date is still 6 hours after the previous one.

### The `start_date` trap

`start_date` is **inclusive**: Airflow will produce a DAG run for the first complete interval *after* `start_date`. Set it to a past date with `catchup=False` and you get one run (the most recent interval). Set it to the future and Airflow waits.

**Never use `datetime.now()` as `start_date`.** It changes every time the scheduler re-imports the DAG file, which causes the scheduler to see a new `start_date` every scan and behave erratically (creating/skipping runs). Use a fixed timestamp:

```python
start_date=datetime(2024, 6, 1, tzinfo=timezone.utc)
```

---

## Backfills & Catchup

`catchup=True` (the default) means: "if there are historical intervals between `start_date` and now that have no DAG run, create them." On a new production DAG with a `start_date` six months ago, this triggers hundreds of concurrent runs and floods your workers.

```
start_date=2024-01-01, catchup=True, today=2024-07-01
→ Airflow schedules 181 historical runs immediately
```

**Rule:** set `catchup=False` on every new DAG unless you explicitly want historical replay. Do backfills manually:

```bash
airflow dags backfill \
  --start-date 2024-01-01 \
  --end-date   2024-01-31 \
  ingest_events
```

`backfill` is sequential by default (one logical date at a time). Add `--reset-dagruns` if runs already exist and you want to re-execute them. Add `--delay-on-limit 60` to throttle.

---

## Idempotent Tasks

An idempotent task: given the same `logical_date`, running it once, twice, or twenty times produces exactly the same final state in the sink. This is the correctness invariant that makes retrys and backfills safe.

Patterns for idempotency:

| Pattern | Implementation |
|---------|---------------|
| Overwrite, don't append | `INSERT OVERWRITE` or `DELETE WHERE ds='{{ ds }}' + INSERT`, never bare `INSERT INTO` |
| Partition-replace | Write to `date=2024-01-01/` partition, overwrite the whole partition atomically |
| Upsert with natural key | `INSERT ... ON CONFLICT (id, ds) DO UPDATE SET ...` |
| Staging + swap | Write to `table_tmp_{{ ds }}`, validate, then `ALTER TABLE RENAME` |

The most common idempotency mistake is using a mutable target with append semantics and no deduplication — a retry doubles the rows.

---

## Retries & SLAs

```python
default_args={
    "retries": 3,
    "retry_delay": timedelta(minutes=5),
    "retry_exponential_backoff": True,    # 5m, 10m, 20m
    "max_retry_delay": timedelta(hours=1),
    "sla": timedelta(hours=2),            # alert if task hasn't finished within 2h of logical_date
}
```

**SLAs in Airflow** are measured from the DAG's scheduled execution date, not from task start time. An SLA miss sends an email (if SMTP is configured) and records a `sla_miss` row — it does not fail the task. SLA misses are surfaced in the Airflow UI under Browse → SLA Misses.

Common `retry_exponential_backoff=True` misuse: teams set `retries=10` with exponential backoff and wonder why a bad partition floods the target 10 times on rerun. Pair high retry counts with idempotent sinks.

---

## Sensors

Sensors are a special operator subclass: they block (keep polling) until a condition is true. They occupy a worker slot for their entire polling duration — this is the primary source of worker slot exhaustion.

```python
from airflow.sensors.filesystem import FileSensor
from airflow.sensors.python import PythonSensor

wait_for_file = FileSensor(
    task_id="wait_for_upstream",
    filepath="/data/landing/{{ ds }}/marker.done",
    poke_interval=60,          # check every 60 seconds
    timeout=3600,              # fail after 1 hour
    mode="reschedule",         # IMPORTANT: release worker slot between pokes
)
```

**`mode="reschedule"` vs `mode="poke"`:** `poke` (default) holds the worker slot open and sleeps. On a cluster with 8 Celery workers, 8 concurrent sensors in poke mode starve every actual task. `reschedule` releases the slot between checks — the scheduler re-queues the sensor at the next poke time. Use `reschedule` for anything polling more than a few seconds.

```
mode="poke"        → 1 sensor = 1 worker slot occupied for the full timeout
mode="reschedule"  → 1 sensor = slot used only during the actual probe (milliseconds)
```

---

## The Executor Model

The executor is what actually runs tasks. It determines concurrency limits, deployment shape, and failure blast radius.

```
┌──────────────┬───────────────────────────────────────────────────────────────┐
│ Executor     │ Characteristics                                               │
├──────────────┼───────────────────────────────────────────────────────────────┤
│ Sequential   │ One task at a time. Dev/testing only.                        │
│ Local        │ Multi-process on the scheduler host. Small scale.            │
│ Celery       │ Tasks dispatched to a Celery broker (Redis/RabbitMQ).        │
│              │ Horizontal scaling: add workers. Default in managed Airflow. │
│ Kubernetes   │ Each task runs as a distinct K8s Pod. Perfect isolation,     │
│              │ slower start (pod spin-up). Best for heterogeneous deps.     │
├──────────────┴───────────────────────────────────────────────────────────────┤
│ Key insight: Executor only determines WHERE tasks run, not WHAT they do.    │
│ The DAG definition is identical across all executors.                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

**KubernetesExecutor at SAP-scale:** each task pod gets its own CPU/memory request. A task that peaks at 16 GB RAM doesn't starve other tasks — it gets a dedicated pod. The tradeoff is latency: pod spin-up (image pull, scheduler binding) adds 15–60 seconds versus a warm Celery worker.

---

## Debugging Orchestration

Most Airflow incidents fall into four patterns. Read the symptom, find the cause, apply the fix — always check the task log first (`Browse → Task Instances → Log`).

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Backfill produces duplicate rows (counts double, triple) | Task appends instead of overwrites; `execution_date` not used for partitioning | Rewrite sink to `DELETE WHERE ds=... + INSERT` or use partition-replace; never bare `INSERT INTO` |
| DAG runs behind by exactly one schedule interval | Off-by-one: `execution_date` is the interval *start*, task runs at interval *end* | Stop using `datetime.now()` — use `context["ds"]` everywhere; add a log line to confirm |
| Daily DAG triggers twice (duplicate runs) | Two files define the same `dag_id`, or a variable `start_date=datetime.now()` causes re-registration | Grep DAG files for duplicate `dag_id`; fix `start_date` to a static value |
| Task stays in `scheduled` or `queued` forever (deadlock) | Worker slots exhausted by sensors in `mode="poke"`, or `depends_on_past=True` with a predecessor failure | Switch sensors to `mode="reschedule"`; clear the blocking predecessor task in the UI; check `AIRFLOW__CORE__PARALLELISM` |
| Task disappears from the UI; logs show `zombie detected` | Worker process died (OOM, SIGKILL from K8s) mid-task; scheduler detected no heartbeat for `zombie_detection_interval` | Check worker pod logs/node events; the scheduler will re-queue after `zombie_threshold_time`; size worker pods appropriately |
| `catchup=True` spawns hundreds of runs at DAG deploy | Default `catchup` left on; `start_date` is months in the past | Set `catchup=False`; pause the DAG, clear the queue, run `backfill` manually with a date range |

### Going deeper on zombie tasks

Zombie detection logic (Airflow 2.x): the scheduler periodically queries `task_instance` rows where `state=running` and `latest_heartbeat < now() - zombie_threshold`. When found, it marks the task `failed` (or `up_for_retry`) and logs:

```
Detected zombie job with id <tid> and external pid <pid>. Marked it as failed.
```

On the KubernetesExecutor, the equivalent is a pod in `OOMKilled` or `Error` state. The scheduler reconciles via the pod API — it compares running pods against expected `task_instance` states. To diagnose:

```bash
kubectl -n airflow get pods --sort-by=.metadata.creationTimestamp | tail -20
kubectl -n airflow logs <task-pod-name> --previous
kubectl -n airflow describe pod <task-pod-name> | grep -A5 "Last State"
```

> **War story.** A quarterly reporting DAG at an e-commerce platform was producing correct-looking numbers but with a subtle count inflation that only showed up on the third day of the month. Root cause: the `load_transactions` task used `INSERT INTO fact_transactions SELECT ... FROM staging WHERE event_date = '{{ ds }}'` — no `DELETE` before the insert. A task retry (triggered by a transient DB timeout) was appending a second copy of the partition. Because the retry only happened ~20% of days, it passed QA most months. The fix was two lines: prepend `DELETE FROM fact_transactions WHERE event_date = '{{ ds }}';` before the insert. The lesson: **every task that writes to a shared sink must be idempotent end-to-end, not just "hopefully runs once."**

---

## Checkpoint

You're solid on orchestration when you can, without looking anything up:

1. Explain why `datetime.now()` in a task is always wrong — what does Airflow pass in `context["ds"]` instead, and why does the offset exist?
2. Given `start_date=2023-01-01`, `catchup=True`, and today being 2024-01-01, how many DAG runs does Airflow create, and how do you prevent this on a new deployment?
3. Design an idempotent daily load task for a `fact_orders` table — what is the exact sequence of SQL operations?
4. Explain the difference between `mode="poke"` and `mode="reschedule"` for a `FileSensor` and why `poke` can starve your entire cluster.
5. Distinguish CeleryExecutor from KubernetesExecutor: which has lower task latency, which gives better resource isolation, and when do you prefer each?
6. Describe the zombie detection cycle: how does the scheduler detect a dead task, and what should you check when a KubernetesExecutor pod disappears?
7. You have a pipeline where yesterday's `validate` task failed. Today's `validate` is stuck in `scheduled`. What caused this, and what are your two remediation options?

➡ Next up: **Storage & Modeling** — where the data your pipelines produce actually lives, and how the choice of file format and schema structure determines whether your queries take 200ms or 20 minutes.
