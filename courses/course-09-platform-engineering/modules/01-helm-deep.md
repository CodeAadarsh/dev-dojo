# Helm, Deeply

> **Module 01 · Course 09** — You know `helm install` and `helm upgrade`. This module covers what's actually happening: how templates are evaluated, how named helpers DRY up repetition, how dependencies compose charts, how hooks sequence workload operations, and how to ship a chart that passes a chart-testing gate. The goal is to graduate from "Helm user" to "chart author."

You already apply Helm charts from upstream (cert-manager, kube-prometheus-stack, Loki). Here the lens flips: you're the author, and your customers are the teams whose 3 AM pages depend on your chart being correct.

---

## Chart anatomy

A Helm chart is a directory (or tarball) with a predictable structure:

```
myapp/
  Chart.yaml          # chart identity and dependency declarations
  values.yaml         # default values — the public API of your chart
  values.schema.json  # optional: OpenAPI schema to validate values at install time
  templates/
    _helpers.tpl      # named templates — never rendered directly as objects
    deployment.yaml
    service.yaml
    hpa.yaml
    NOTES.txt         # printed to stdout after install/upgrade
  charts/             # vendored dependency charts (populated by helm dep update)
  .helmignore
```

`Chart.yaml` minimum viable shape:

```yaml
apiVersion: v2          # v1 is legacy Helm 2; always v2 for new charts
name: myapp
version: 1.3.0          # semver of the chart itself — governs helm rollback
appVersion: "2.7.1"     # version of the app this packages (for display only)
type: application       # "application" | "library"
description: Deploys the myapp service with its configurable options.
```

Key distinction: `version` governs `helm upgrade/rollback` — it's what `helm history` shows. `appVersion` is a string for humans. Bumping only `appVersion` without bumping `version` won't register as a new revision.

---

## Templates: Go + Sprig

Every file in `templates/` (except `_helpers.tpl` and `NOTES.txt`) is rendered by Go's `text/template` engine plus the [Sprig](http://masterminds.github.io/sprig/) function library.

### Value access and defaults

```yaml
# templates/deployment.yaml
spec:
  replicas: {{ .Values.replicaCount | default 2 }}
  template:
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

Built-in objects:
- `.Values.*` — from `values.yaml` or caller overrides
- `.Chart.*` — fields from `Chart.yaml`
- `.Release.*` — `Name`, `Namespace`, `Revision`, `IsInstall`, `IsUpgrade`

`toYaml | nindent N` is the idiom for embedding arbitrary YAML blocks cleanly. Always use it for `resources`, `affinity`, `tolerations`, `env` arrays.

### Conditionals and ranges

```yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "myapp.fullname" . }}
  ...
{{- end }}
```

```yaml
env:
  {{- range $key, $val := .Values.extraEnv }}
  - name: {{ $key }}
    value: {{ $val | quote }}
  {{- end }}
```

The `{{- ` / ` -}}` whitespace-trim markers remove blank lines that would otherwise appear around control blocks. Use them consistently inside `if`/`range`/`with`.

---

## Named templates & `_helpers.tpl`

Files prefixed with `_` are never rendered as Kubernetes objects — they exist solely as named template libraries called with `include`.

```yaml
# templates/_helpers.tpl

{{/*
Chart name, overridable via .Values.nameOverride. Truncated at 63 chars.
*/}}
{{- define "myapp.name" -}}
{{- .Values.nameOverride | default .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels — used by both Deployment.spec.selector and Service.spec.selector.
Only put stable labels here; never chart version (selector is immutable after creation).
*/}}
{{- define "myapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "myapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Full label set — includes chart version; use on metadata, not selectors.
*/}}
{{- define "myapp.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ include "myapp.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Full resource name: release-name + chart-name, capped at 63 chars.
*/}}
{{- define "myapp.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "myapp.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
```

Consuming the helpers:

```yaml
# templates/deployment.yaml
metadata:
  name: {{ include "myapp.fullname" . }}
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- include "myapp.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "myapp.selectorLabels" . | nindent 8 }}
```

**`include` vs `template`:** always use `include`. Unlike `template`, `include` returns a string you can pipe to `nindent`, `quote`, or any other function. `template` writes directly to the output stream and can't be piped — it's a footgun in any non-trivial template.

---

## Values precedence (the stack)

Helm evaluates values in lowest-to-highest priority order:

```
chart's values.yaml                               ← lowest priority
  └── dependency subchart values.yaml
       └── parent chart values.yaml (key = subchart name)
            └── -f myfile.yaml  (each -f left to right)
                 └── --set key=value              ← highest priority
```

Practical consequence: `helm upgrade myapp . --set image.tag=v2 -f prod.yaml` — `--set` beats `prod.yaml` beats `values.yaml`. This order trips people up when a `-f` override isn't taking effect because a `--set` flag elsewhere in the deploy script is overriding it silently.

Inspect what Helm actually received before rendering:

```bash
helm get values myapp -n dojo-helm              # user-supplied values for this release
helm get values myapp -n dojo-helm --all        # merged with chart defaults — what templates saw
helm show values oci://ghcr.io/org/chart --version 1.3.0   # defaults from a remote chart
```

---

## Dependencies / subcharts

Declare dependencies in `Chart.yaml`:

```yaml
dependencies:
  - name: postgresql
    version: "15.2.5"
    repository: "https://charts.bitnami.com/bitnami"
    condition: postgresql.enabled       # skip if .Values.postgresql.enabled is false
  - name: redis
    version: "19.1.0"
    repository: "oci://registry-1.docker.io/bitnamicharts"
    tags:
      - cache                           # enable/disable the whole tag group via .Values.tags.cache
```

```bash
helm dependency update ./myapp         # downloads into myapp/charts/, writes Chart.lock
helm dependency list ./myapp           # shows status: ok | missing | wrong version
```

Override a subchart's values from the parent by nesting under the subchart name:

```yaml
# values.yaml (parent chart)
postgresql:
  enabled: true
  auth:
    database: myapp
    username: myapp
  primary:
    persistence:
      size: 10Gi
```

The `postgresql:` key maps exactly to the dependency `name`. Everything nested beneath it is passed verbatim to the subchart's values.

---

## Hooks

Hooks attach Jobs (or any manifest) to Helm lifecycle events. The canonical pattern: run a database migration before upgrading, clean up afterward.

```yaml
# templates/migrate-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "myapp.fullname" . }}-migrate
  annotations:
    "helm.sh/hook": pre-upgrade,pre-install
    "helm.sh/hook-weight": "-5"                 # lower number runs first; default 0
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 1
  activeDeadlineSeconds: 120
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          command: ["./migrate", "--run"]
```

Available hook annotations:

| Hook | Fires |
|------|-------|
| `pre-install` | Before any objects are created on first install |
| `post-install` | After all objects are created on first install |
| `pre-upgrade` | Before any objects are updated on upgrade |
| `post-upgrade` | After all objects are updated on upgrade |
| `pre-delete` | Before `helm uninstall` removes objects |
| `post-delete` | After `helm uninstall` removes objects |
| `pre-rollback` | Before `helm rollback` applies the previous release |
| `post-rollback` | After rollback completes |
| `test` | Run by `helm test` — covered below |

**Delete policy matters.** `hook-succeeded` removes the Job only on success (you keep it around on failure for debugging). `before-hook-creation` removes the old Job before creating a new one, making upgrades idempotent. Without any delete policy the hook resources accumulate indefinitely — you'll find dozens of stale migration Jobs after a few months.

---

## OCI registries

Helm 3.8+ supports OCI as a first-class registry — no `helm repo add` step, no `helm repo update`, no index.yaml:

```bash
# Package and push
helm package ./myapp                          # produces myapp-1.3.0.tgz
helm push myapp-1.3.0.tgz oci://ghcr.io/myorg/charts

# Inspect before install
helm show all oci://ghcr.io/myorg/charts/myapp --version 1.3.0

# Install directly from OCI
helm install myapp oci://ghcr.io/myorg/charts/myapp \
  --version 1.3.0 -n dojo-helm --create-namespace

# Authenticate
helm registry login ghcr.io -u <username> --password-stdin
helm registry logout ghcr.io
```

OCI refs: `oci://registry/path-to-repo` — the chart name comes from the dependency `name` key, not the repo URL. In `Chart.yaml` dependencies:

```yaml
dependencies:
  - name: mylib
    version: "0.1.0"
    repository: "oci://ghcr.io/myorg/charts"   # no chart name here
```

---

## Release lifecycle & rollback

Helm stores each release revision as a Secret in the release namespace (Helm 3 default). Every `helm upgrade` creates a new revision:

```bash
helm list -n dojo-helm                              # all releases in namespace
helm history myapp -n dojo-helm                     # every revision: status, chart, app version
helm get manifest myapp --revision 2 -n dojo-helm   # exact YAML that revision applied
helm get values myapp --revision 2 -n dojo-helm     # values used at revision 2
```

Rollback:

```bash
helm rollback myapp 2 -n dojo-helm    # rolls back to revision 2 → creates new revision N+1
helm rollback myapp 0 -n dojo-helm    # 0 = one revision before current
```

Rollback always creates a new revision — it never removes history. After rollback, `helm history` shows `deployed` on the new revision and `superseded` on the previous one.

Release states worth knowing:

| State | Meaning |
|-------|---------|
| `deployed` | Active revision |
| `superseded` | A previous successful revision |
| `failed` | The most recent install/upgrade failed; previous revision is still serving |
| `pending-install` / `pending-upgrade` | Helm is mid-operation, or it died mid-flight |
| `uninstalling` | `helm uninstall` in progress |

---

## Library charts

A library chart (`type: library`) contains only named templates — it never renders Kubernetes objects. Consume it as a dependency and call its helpers with `include`.

```yaml
# mycorp-lib/Chart.yaml
apiVersion: v2
name: mycorp-lib
version: 0.4.0
type: library
description: Shared templates enforcing corp security baseline.
```

```yaml
# mycorp-lib/templates/_containers.tpl
{{- define "mycorp-lib.secureContainer" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  capabilities:
    drop: [ALL]
resources:
  requests:
    cpu: {{ .cpu | default "50m" }}
    memory: {{ .memory | default "64Mi" }}
{{- end }}
```

Consuming chart:

```yaml
# my-service/Chart.yaml
dependencies:
  - name: mycorp-lib
    version: "0.4.0"
    repository: "oci://ghcr.io/mycorp/charts"
```

```yaml
# my-service/templates/deployment.yaml
containers:
  - name: app
    image: "{{ .Values.image }}:{{ .Values.tag }}"
    {{- include "mycorp-lib.secureContainer" (dict "cpu" "100m" "memory" "128Mi") | nindent 4 }}
```

This is how platform teams enforce security posture across services — one change to the library chart propagates to every chart that bumps the dependency version.

---

## Testing

### `helm test`

Tests are Pods annotated `helm.sh/hook: test`. Helm creates them, waits for exit 0, and deletes them:

```yaml
# templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: {{ include "myapp.fullname" . }}-test-connection
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  restartPolicy: Never
  containers:
    - name: wget
      image: busybox:1.36
      command:
        - wget
        - --spider
        - --timeout=5
        - http://{{ include "myapp.fullname" . }}:{{ .Values.service.port }}/healthz
```

```bash
helm test myapp -n dojo-helm           # runs all test hooks
helm test myapp -n dojo-helm --logs    # tails test pod output before deletion
```

### chart-testing (`ct`)

`ct` is the CI gate for Helm charts in a monorepo. It detects changed charts, lints them, installs on a test cluster, runs `helm test`, and cleans up:

```bash
ct lint --config ct.yaml             # lint only — no cluster needed
ct install --config ct.yaml          # install + helm test on current context
ct lint-and-install --config ct.yaml # both, the standard CI step
```

Minimal `ct.yaml`:

```yaml
chart-dirs:
  - charts
helm-extra-args: "--timeout 120s"
validate-chart-schema: true
validate-maintainers: true
```

`ct lint` enforces things `helm lint` doesn't: chart version must be bumped when values.yaml changes, `maintainers` field required, `values.schema.json` recommended. It's the Helm equivalent of a CI lint gate.

---

## Debugging Helm

Helm failures fall into three buckets: template didn't render what you expected, a release is stuck in a non-deployed state, or a value override isn't taking effect. Diagnose cheapest-first.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Error: template: myapp/templates/deployment.yaml:42: wrong type for value; expected string, got map` | A `.Values.x` map is embedded raw — missing `toYaml` | Wrap: `toYaml .Values.x \| nindent N` |
| `Error: INSTALLATION FAILED: cannot re-use a name that is still in use` | Previous install left a `failed` or `pending` release | `helm uninstall myapp -n ns` then reinstall, or use `helm upgrade --install` |
| Release stuck in `pending-install` / `pending-upgrade` | Helm process died mid-flight; revision Secret lock not released | Find and delete the stuck revision Secret (see commands below) |
| `helm rollback` fails: `Error: release has no deployed releases` | All revisions are `failed`; rollback needs a `deployed` anchor | `helm history` to find the last-good chart version; `helm upgrade --install` from that |
| `--set key=val` override silently ignored | Override path doesn't match the template's `.Values.` path (casing, nesting) | `helm template . --set key=val \| grep key` to see what rendered |
| Hook Job not visible after upgrade | `before-hook-creation` policy deleted it; or hook annotation typo | `kubectl -n ns get jobs` immediately after `helm upgrade`; `helm get hooks release` |

### Diagnose — exact commands

**Template render errors.** Always render locally before applying to the cluster:

```bash
helm template myapp . -f values.yaml --debug 2>&1 | head -80
helm lint .                      # basic lint pass
helm lint . --strict             # warnings become errors
```

`--debug` dumps the computed value map AND the full rendered templates. If the error points to line 42 of deployment.yaml, you can see exactly what Helm tried to write.

**Stuck / failed release.**

```bash
# Helm 3 stores revisions as Secrets
kubectl -n dojo-helm get secrets -l owner=helm,name=myapp \
  --sort-by=.metadata.creationTimestamp

# Read the stuck revision's status label
kubectl -n dojo-helm get secret sh.helm.release.v1.myapp.v3 \
  -o jsonpath='{.metadata.labels.status}{"\n"}'

# Delete only that revision Secret — keeps the rest of history intact
kubectl -n dojo-helm delete secret sh.helm.release.v1.myapp.v3

# Retry with --atomic so it auto-rolls-back on timeout
helm upgrade myapp . -n dojo-helm --install --atomic --timeout 3m
```

**Values precedence confusion.**

```bash
helm get values myapp -n dojo-helm --all   # the merged set — exactly what templates received
helm template . --set image.tag=v2 -f prod.yaml --debug 2>&1 | grep -A2 "image:"
```

> **War story.** Our team runs biweekly Helm upgrades for Loki on the SAP LGTM cluster. One upgrade silently entered `pending-upgrade` and timed out — the revision never moved to `deployed`. `helm history` showed revision 7 as `pending-upgrade`. Checking `kubectl -n logging get jobs` revealed the pre-upgrade hook Job was in `BackoffLimitExceeded` — it had exceeded its `activeDeadlineSeconds`, but Helm surfaced this only as a generic timeout, not a hook error. Fix: delete the pending revision Secret, bump `activeDeadlineSeconds` to 180s in the hook Job, re-upgrade. After that, every upgrade command in our deploy pipeline uses `--atomic --timeout 3m` so a hook failure auto-rolls-back instead of leaving the release in a permanently stuck state. The `pending-*` state is the Helm equivalent of a semaphore no one released.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain the difference between chart `version` and `appVersion`, and which one governs `helm rollback`.
2. Write a `_helpers.tpl` named template that produces standard labels and call it with `include` + `nindent`.
3. List the values precedence order from lowest to highest, and identify why `--set` beats `-f`.
4. Add a PostgreSQL dependency to `Chart.yaml`, run `helm dep update`, and override one of its values from the parent.
5. Write a `pre-upgrade` hook Job with `before-hook-creation,hook-succeeded` delete policy and weight `-5`.
6. Push a packaged chart to an OCI registry and install it with `helm install oci://...`.
7. Roll a release back to revision 2 and explain what `helm history` shows afterward.
8. Unstick a release in `pending-upgrade` state without losing revision history.
9. Run `helm test` and explain what happens if the test Pod exits 1.
10. Name one thing `ct lint-and-install` enforces that `helm lint` alone does not.

➡ Next: **Kustomize, Deeply** — pure-YAML patching for when Helm's template engine is more than you need.
