# PromQL Hunt

An engineer tells you: "The flag is in Prometheus. Look at the metrics." That's all you get.

Some teams encode operational metadata — build SHAs, feature-flag versions, config checksums — into Prometheus metric labels so they're queryable alongside performance data. A `dojo_flag_info` metric was emitted by a recently deployed app. The flag is the *value* of one of its labels. PromQL can read label values directly.

## Prereqs

kube-prometheus-stack must be installed in namespace `monitoring`:

```bash
bash labs/bootstrap/install-monitoring.sh
```

## Mission

1. Run `setup.sh` to plant the scenario (deploys the app and wires its ServiceMonitor so Prometheus scrapes it).
2. Port-forward Prometheus:
   ```bash
   kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090
   ```
3. Open `http://localhost:9090` and go to **Graph**.
4. Write a PromQL query that exposes the `dojo_flag_info` metric and read the value of its `flag` label.
5. Submit that label value — it is the flag in `KUBE{...}` form.

## Hints on extraction paths

There are at least two ways to read the value once you know the metric name:

- **Prometheus UI / Graph tab:** query `dojo_flag_info` — the result row shows all label key=value pairs.
- **HTTP API directly:** `curl -s 'http://localhost:9090/api/v1/query?query=dojo_flag_info' | python3 -m json.tool` — the `metric` field in the result contains the labels.

No `verify.sh` — the flag speaks for itself.

## Why this matters

Prometheus labels are metadata attached to every time-series sample. A poorly designed metric can embed PII, internal hostnames, or secrets in labels and have them scraped, stored, and queryable by anyone with Prometheus access. High-cardinality labels (e.g., `user_id`, `request_id`) are also a common cause of Prometheus memory explosions at scale — the same reason you log at 100 GB/day but think carefully about cardinality on the LGTM stack.
