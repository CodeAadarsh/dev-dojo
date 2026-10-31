# Helm Chart with Values Override

Your team's platform mandate just landed: *every service must ship as a Helm chart.* The first candidate is a simple nginx-based portal. You need to scaffold the chart, customise it with a values file, and prove the release is running in the cluster the way the manifest says it should.

This is day-one Helm work, but it reveals something important: the default `helm create` scaffold is opinionated and the template helpers (`fullname`, `labels`) are wiring you may not immediately understand. Work through it once deliberately and it becomes a load-bearing mental model.

## Mission

1. Use `helm create` to scaffold a chart (pick any chart name).
2. Install it as release **`portal`** into namespace **`dojo-helm2`** with the following values overrides:
   - `replicaCount=2`
   - `image.repository=nginx`
   - `image.tag=1.27-alpine`
3. Confirm the release is in `deployed` status.

The verifier checks:

- `helm -n dojo-helm2 list -q` contains `portal`.
- The Deployment labelled `app.kubernetes.io/instance=portal` has exactly **2 replicas** and all replicas are Ready.
- The container image starts with `nginx`.

## PREREQ

`helm` must be on your PATH. Verify with `helm version`. If missing:

```bash
brew install helm          # macOS
# or: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## Rules of engagement

- Work in namespace `dojo-helm2` (setup.sh creates it).
- Scaffold the chart in a temp directory outside the kube-dojo tree.
- You may use `--set` flags or a `-f values.yaml` file on `helm install`; both are accepted.
- The verifier only inspects the live cluster and the helm release list — how you installed is your business.

When the cluster matches the target, run the verifier:

```bash
bash courses/course-09-platform-engineering/challenges/01-helm-with-values/verify.sh
```
