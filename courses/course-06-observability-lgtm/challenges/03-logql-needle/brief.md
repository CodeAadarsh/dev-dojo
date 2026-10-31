# LogQL Needle

**Incident bridge, 02:47:** "We're seeing anomalous output in the `log-flood` pod. Something in those logs has the information you need, but there are thousands of lines. Find it fast."

In production, pod logs at any meaningful scale are unreadable with `kubectl logs` alone. Loki + LogQL is the upgrade — a grep-like filter that runs against centralized, indexed log streams without pulling every line to your laptop.

## Prereqs

**Loki** (optional but preferred path): if you have a Loki deployment, port-forward Grafana and use LogQL. The kube-prometheus-stack (`labs/bootstrap/install-monitoring.sh`) installs Grafana but **not** Loki. To add Loki, install the Grafana Loki stack separately or use the Grafana Explore → Loki datasource if already configured.

**Fallback** (always works): `kubectl logs` + `grep` — all the signal, none of the style. The brief intentionally supports both paths.

## Scenario

`setup.sh` deploys a single pod named `log-flood` in namespace `dojo-obs`. It logs an endless stream of realistic-looking but fake HTTP access log lines. One log line — and only one — contains the string `FLAG=KUBE{...}`. It is surrounded by thousands of lines that look identical at a glance.

## Mission

Find the line containing `FLAG=` and extract the value.

**Path 1 — LogQL in Grafana (primary)**

```bash
kubectl -n monitoring port-forward svc/kps-grafana 3000:80 &
# open http://localhost:3000 (admin / admin)
# Explore → Loki datasource → LogQL query:
#   {namespace="dojo-obs", pod=~"log-flood.*"} |= "FLAG="
```

The single matching line contains the full flag value.

**Path 2 — kubectl logs (fallback, always works)**

```bash
kubectl -n dojo-obs logs -l app=log-flood --tail=-1 | grep 'FLAG='
```

`--tail=-1` means "all lines." `grep 'FLAG='` filters to the one needle.

## Why this matters

At 100 GB/day of logs, `kubectl logs` is a disaster: it streams the whole pod log over the API server, saturates the network, and times out on long-running pods. LogQL filters run *at the log store* — only the matching bytes leave Loki. That's the operational reason Loki exists: efficient needle-in-a-haystack retrieval without pulling the haystack.

No `verify.sh` — the flag speaks for itself.
