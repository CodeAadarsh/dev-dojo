# Package It With Helm

Your team ships a service as a folder of fourteen YAML files. The staging and prod copies drifted three sprints ago, nobody can tell you which image tag is actually running without `kubectl get`, and "rolling back" means `git revert` plus a prayer. You already know the fix — you install cert-manager and the Prometheus Operator with Helm at work — but you've never *authored* the packaging side. Time to.

A **Helm chart** is a parameterized, versioned bundle of Kubernetes manifests. A **release** is one named *installation* of a chart into a cluster, with its *values* and a full revision history you can roll back to. That's the leap: from "apply a pile of YAML" to "install version 2.3.1 of an app as release `web`, and roll back to revision 2 in one command."

```
   chart (templates + default values)          release "web" (a stateful install)
   ┌───────────────────────────────┐           ┌──────────────── history ──────────────┐
   │ templates/deployment.yaml  ────┼── render ─┤ rev 1  install   nginx:1.27-alpine      │
   │ templates/service.yaml         │   with    │ rev 2  upgrade   replicas 1→3           │
   │ values.yaml  (defaults)        │  values   │ rev 3  upgrade   nginx:1.27  (bad)       │
   │ Chart.yaml   (name+version)    │           │ rev 4  rollback→2  (back to known-good) │
   └───────────────────────────────┘           └─────────────────────────────────────────┘
             helm install/upgrade  ───────────────►  objects live in the cluster
```

## The four verbs that matter

| Verb | Command | What it does |
|------|---------|--------------|
| install | `helm install web <chart> -n dojo-helm` | Create release `web` = render chart with values, apply to cluster, record revision 1 |
| upgrade | `helm upgrade web <chart> -n dojo-helm --set replicaCount=3` | Re-render with new values/version, diff, apply, record a new revision |
| rollback | `helm rollback web 2 -n dojo-helm` | Re-apply a previous revision's exact manifests, recorded as a *new* revision |
| uninstall | `helm uninstall web -n dojo-helm` | Delete all release objects and (by default) its history |

Values are the whole point: one chart, many installs that differ only by `--set` / `-f values.yaml`. Where that history lives is worth knowing — Helm 3 stores each release revision as a **Secret** of type `helm.sh/release.v1` *in the release's namespace* (`kubectl -n dojo-helm get secret -l owner=helm`). There is no Tiller, no cluster-wide server; `helm` is a client that talks to the API server as you, and the release state is just Secrets. That is why `rollback` works offline-of-git and why deleting those Secrets orphans a release.

## Mission

Install a Helm release into namespace `dojo-helm`. You pick the chart — both of these are fully accepted:

- **Scaffold a local chart** with `helm create web`, then `helm install web ./web -n dojo-helm` (the default chart is an nginx Deployment + Service + probes — ideal here).
- **Install from a repo**: an OCI chart (`helm install web oci://...`) or a classic repo chart (`helm repo add ... && helm install web <repo>/<chart> -n dojo-helm`).

Either way, the release **must be named `web`**.

## Target state — exactly what the verifier checks

The verifier accepts your work only when **all** of these hold:

1. **A Helm release named `web` exists in `dojo-helm`** — i.e. `helm -n dojo-helm list -q` prints a line that is exactly `web`.
2. **That release's workload is actually Ready** — a Deployment or StatefulSet carrying Helm's standard label `app.kubernetes.io/instance=web` reports `readyReplicas >= 1`. A release that installed but whose pods are `Pending`/`ImagePullBackOff` does **not** count.

> Pin your image. The default `helm create` chart installs `nginx` at the chart's `appVersion` — fine — but if you set a tag, set a real one (`--set image.tag=1.27-alpine`), never `latest`. A floating tag is exactly the drift Helm is supposed to kill.

## Rules of engagement

- Work in namespace `dojo-helm` (the setup script creates it).
- `helm` must be installed (it's a prerequisite for this challenge).
- Run the verifier when you believe the release is up and Ready; it inspects live cluster state and prints the flag only when every check passes.

## Why this matters

Hand-applied YAML has no identity, no version, and no atomic rollback. A Helm release gives you all three: a named unit you can `list`, `history`, `diff`, and `rollback` as one transaction. The failure you're preventing is the 2am one where a bad config ships, the fix is "go back to what worked," and without release history your only "previous state" is whatever you can reconstruct from memory and `git log`.
