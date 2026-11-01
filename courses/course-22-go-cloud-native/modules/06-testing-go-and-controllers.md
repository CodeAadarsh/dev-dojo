# Testing Go & Controllers

> **Module 06 · Course 22** — "It works on my machine" doesn't survive a merge queue. This module covers three concentric layers of controller testing: table-driven unit tests for pure functions, fake-client tests for the reconciler without a running cluster, and envtest for a real API server started in-process. Each layer catches a different class of bug; knowing which to reach for saves hours of debugging.

---

## The three testing layers

```
┌──────────────────────────────────────────┐
│  envtest (integration)                   │  real kube-apiserver + etcd process
│  ┌────────────────────────────────────┐  │
│  │  fake client (controller unit)     │  │  real reconciler, no cluster process
│  │  ┌──────────────────────────────┐  │  │
│  │  │  table-driven unit tests     │  │  │  pure Go functions, zero Kubernetes
│  │  └──────────────────────────────┘  │  │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
```

Unit tests run in milliseconds. Fake-client controller tests run in under a second. Reserve envtest for cases that require real API server semantics: admission webhooks, status subresource validation, real watch delivery. Treat the layers as complements — most controller logic belongs in the fake-client layer.

---

## Table-driven tests

Table-driven is Go's idiomatic test structure. One function, a slice of named cases, a single loop.

```go
func TestBuildDeploymentSpec(t *testing.T) {
    cases := []struct {
        name    string
        spec    appsv1.WidgetSpec
        wantRep int32
        wantImg string
    }{
        {
            name:    "defaults",
            spec:    appsv1.WidgetSpec{Replicas: 1, Image: "nginx:1.27-alpine"},
            wantRep: 1,
            wantImg: "nginx:1.27-alpine",
        },
        {
            name:    "scale to 5",
            spec:    appsv1.WidgetSpec{Replicas: 5, Image: "myapp:v2"},
            wantRep: 5,
            wantImg: "myapp:v2",
        },
        {
            name:    "zero replicas clamped to 1",
            spec:    appsv1.WidgetSpec{Replicas: 0, Image: "myapp:v2"},
            wantRep: 1,
            wantImg: "myapp:v2",
        },
    }

    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            deploy := buildDeploymentSpec(&appsv1.Widget{Spec: tc.spec})
            if got := *deploy.Replicas; got != tc.wantRep {
                t.Errorf("replicas: got %d, want %d", got, tc.wantRep)
            }
            if got := deploy.Template.Spec.Containers[0].Image; got != tc.wantImg {
                t.Errorf("image: got %q, want %q", got, tc.wantImg)
            }
        })
    }
}
```

Use `t.Run(tc.name, ...)` — failures report by name (`TestBuildDeploymentSpec/zero_replicas_clamped_to_1`), not by array index. Run a single case: `go test -run TestBuildDeploymentSpec/scale_to_5`.

Design your reconciler to have a layer of pure functions (`buildDeploymentSpec`, `computeConditions`, `parseImage`) that are trivially unit-testable. The reconciler itself then wires those functions together and is tested at the fake-client layer. This separation is the single biggest factor in keeping a controller maintainable.

---

## Testify assertions

`github.com/stretchr/testify` turns multi-line `if` blocks into single-line assertions. Two sub-packages:

```go
import (
    "testing"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestParseImage(t *testing.T) {
    repo, tag, err := parseImage("myapp:v2.1")
    require.NoError(t, err)         // stops the test immediately on failure
    assert.Equal(t, "myapp", repo)  // continues; collects all failures
    assert.Equal(t, "v2.1", tag)
}
```

`require` vs `assert`: use `require` for preconditions where the rest of the test is meaningless if it fails (no error fetching a resource, object not nil). Use `assert` where you want to see all failures in a single run — `assert` never stops the test.

Common assertions:

```go
assert.Equal(t, expected, actual)
assert.NoError(t, err)
assert.Error(t, err)
assert.Contains(t, slice, element)
assert.Len(t, collection, 3)
assert.True(t, condition, "message when false")
assert.EventuallyWithT(t, func(c *assert.CollectT) {
    assert.Equal(c, "ready", widget.Status.Phase)
}, 5*time.Second, 100*time.Millisecond)
```

`EventuallyWithT` is useful in fake-client tests where you start a goroutine and need to poll for a state change without switching to envtest.

---

## httptest for HTTP handlers

If your operator exposes HTTP (webhook, readiness probe, metrics scrape endpoint), test it without opening a real port:

```go
func TestHealthEndpoint(t *testing.T) {
    handler := NewHealthHandler()
    srv := httptest.NewServer(handler)
    defer srv.Close()

    resp, err := http.Get(srv.URL + "/healthz")
    require.NoError(t, err)
    defer resp.Body.Close()
    assert.Equal(t, http.StatusOK, resp.StatusCode)
}
```

`httptest.NewRecorder` is lighter when you have the handler reference directly — no real port, no `defer Close()`:

```go
w := httptest.NewRecorder()
req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
handler.ServeHTTP(w, req)
assert.Equal(t, http.StatusOK, w.Code)
```

Use `httptest.NewRecorder` for unit-level handler tests; use `httptest.NewServer` when the code under test needs to make real `http.Get` calls (e.g., a webhook client that calls back to itself).

---

## The fake client

`sigs.k8s.io/controller-runtime/pkg/client/fake` provides an in-memory implementation of `client.Client`. No cluster, no goroutines — just a map with the same interface as the real client.

```go
import (
    "context"
    "testing"

    "github.com/stretchr/testify/require"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/runtime"
    "k8s.io/apimachinery/pkg/types"
    "sigs.k8s.io/controller-runtime/pkg/client/fake"
    "sigs.k8s.io/controller-runtime/pkg/reconcile"

    appsv1 "github.com/dojo/widget-operator/api/v1"
    k8sappsv1 "k8s.io/api/apps/v1"
    k8sscheme "k8s.io/client-go/kubernetes/scheme"
)

func TestWidgetReconciler_CreatesDeployment(t *testing.T) {
    scheme := runtime.NewScheme()
    require.NoError(t, appsv1.AddToScheme(scheme))
    require.NoError(t, k8sscheme.AddToScheme(scheme))

    widget := &appsv1.Widget{
        ObjectMeta: metav1.ObjectMeta{Name: "my-widget", Namespace: "default"},
        Spec:       appsv1.WidgetSpec{Replicas: 2, Image: "nginx:1.27-alpine"},
    }

    fakeClient := fake.NewClientBuilder().
        WithScheme(scheme).
        WithObjects(widget).
        WithStatusSubresource(widget). // enables r.Status().Update() semantics
        Build()

    reconciler := &WidgetReconciler{
        Client: fakeClient,
        Scheme: scheme,
    }

    req := reconcile.Request{
        NamespacedName: types.NamespacedName{Name: "my-widget", Namespace: "default"},
    }
    _, err := reconciler.Reconcile(context.Background(), req)
    require.NoError(t, err)

    deploy := &k8sappsv1.Deployment{}
    err = fakeClient.Get(context.Background(),
        types.NamespacedName{Name: "my-widget", Namespace: "default"}, deploy)
    require.NoError(t, err)
    require.Equal(t, int32(2), *deploy.Spec.Replicas)
}
```

Three things that bite everyone once:

- **Register all types.** If your reconciler creates a ConfigMap but `corev1` is not in the scheme, you get a `no kind is registered for the type *v1.ConfigMap` panic — not at scheme setup, but at the first `r.Create(ctx, cm)` call. Register every type your reconciler touches.
- **`WithStatusSubresource(widget)`.** Without this, the fake client merges status writes into the main object path and bypasses the subresource check. Your test passes but it doesn't test the path that will fail on a real cluster.
- **The fake client is synchronous.** `Get` never blocks. There are no watch events, no goroutines — calls complete immediately, which is why this layer is fast but doesn't catch timing-dependent bugs.

### Testing the deletion path

```go
func TestWidgetReconciler_HandlesDeletion(t *testing.T) {
    now := metav1.Now()
    widget := &appsv1.Widget{
        ObjectMeta: metav1.ObjectMeta{
            Name:              "my-widget",
            Namespace:         "default",
            Finalizers:        []string{widgetFinalizer},
            DeletionTimestamp: &now,
        },
        Spec: appsv1.WidgetSpec{Replicas: 1, Image: "nginx:1.27-alpine"},
    }

    scheme := runtime.NewScheme()
    require.NoError(t, appsv1.AddToScheme(scheme))

    fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(widget).Build()
    r := &WidgetReconciler{Client: fakeClient, Scheme: scheme}

    _, err := r.Reconcile(context.Background(), reconcile.Request{
        NamespacedName: types.NamespacedName{Name: "my-widget", Namespace: "default"},
    })
    require.NoError(t, err)

    // after reconcile, the finalizer should be removed
    updated := &appsv1.Widget{}
    _ = fakeClient.Get(context.Background(),
        types.NamespacedName{Name: "my-widget", Namespace: "default"}, updated)
    assert.Empty(t, updated.Finalizers)
}
```

---

## envtest — a real API server for controller tests

`sigs.k8s.io/controller-runtime/pkg/envtest` starts a real `kube-apiserver` and `etcd` as local processes. Your controller runs against them with real watches, real status subresource semantics, and real admission validation.

```go
package controller_test

import (
    "context"
    "os"
    "path/filepath"
    "testing"
    "time"

    . "github.com/onsi/gomega"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/types"
    "k8s.io/client-go/rest"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/envtest"

    appsv1 "github.com/dojo/widget-operator/api/v1"
    k8sappsv1 "k8s.io/api/apps/v1"
)

var (
    cfg       *rest.Config
    k8sClient client.Client
    testEnv   *envtest.Environment
    ctx       context.Context
    cancel    context.CancelFunc
)

func TestMain(m *testing.M) {
    ctx, cancel = context.WithCancel(context.Background())
    defer cancel()

    testEnv = &envtest.Environment{
        CRDDirectoryPaths:     []string{filepath.Join("..", "..", "config", "crd", "bases")},
        ErrorIfCRDPathMissing: true,
    }

    var err error
    cfg, err = testEnv.Start()
    if err != nil {
        panic("envtest start failed: " + err.Error())
    }

    scheme := runtime.NewScheme()
    _ = appsv1.AddToScheme(scheme)
    _ = k8sappsv1.AddToScheme(scheme)

    k8sClient, err = client.New(cfg, client.Options{Scheme: scheme})
    if err != nil {
        panic(err)
    }

    mgr, err := ctrl.NewManager(cfg, ctrl.Options{Scheme: scheme})
    if err != nil {
        panic(err)
    }

    if err = (&WidgetReconciler{
        Client: mgr.GetClient(),
        Scheme: mgr.GetScheme(),
    }).SetupWithManager(mgr); err != nil {
        panic(err)
    }

    go func() {
        if err := mgr.Start(ctx); err != nil {
            panic(err)
        }
    }()

    code := m.Run()
    cancel()
    testEnv.Stop()
    os.Exit(code)
}
```

### Asserting async reconcile results with gomega.Eventually

The API server and the reconciler run in goroutines. Never `time.Sleep` — use `gomega.Eventually` to poll with a timeout:

```go
func TestWidgetCreatesDeployment(t *testing.T) {
    g := NewWithT(t)

    widget := &appsv1.Widget{
        ObjectMeta: metav1.ObjectMeta{
            Name:      "envtest-widget",
            Namespace: "default",
        },
        Spec: appsv1.WidgetSpec{Replicas: 2, Image: "nginx:1.27-alpine"},
    }
    require.NoError(t, k8sClient.Create(ctx, widget))
    t.Cleanup(func() { _ = k8sClient.Delete(ctx, widget) })

    g.Eventually(func() int32 {
        deploy := &k8sappsv1.Deployment{}
        if err := k8sClient.Get(ctx, types.NamespacedName{
            Name: "envtest-widget", Namespace: "default",
        }, deploy); err != nil {
            return 0
        }
        return *deploy.Spec.Replicas
    }, 10*time.Second, 250*time.Millisecond).Should(Equal(int32(2)))
}
```

`Eventually(f, timeout, poll)` calls `f` every `poll` until the gomega matcher passes or `timeout` expires. `250ms` poll is aggressive enough to catch fast reconciles without burning CPU.

### The envtest binary

envtest downloads its own `kube-apiserver` and `etcd` binaries via `setup-envtest`:

```bash
go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest
export KUBEBUILDER_ASSETS=$(setup-envtest use 1.29.x -p path)
go test ./internal/controller/...
```

The binaries land in `~/.local/share/kubebuilder-envtest/`. In CI, cache that path:

```yaml
# .github/workflows/test.yml
- uses: actions/cache@v4
  with:
    path: ~/.local/share/kubebuilder-envtest
    key: envtest-${{ runner.os }}-1.29.x

- name: Download envtest binaries
  run: |
    go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest
    echo "KUBEBUILDER_ASSETS=$(setup-envtest use 1.29.x -p path)" >> "$GITHUB_ENV"

- name: Run tests
  run: go test ./... -race -coverprofile=coverage.out
```

Without caching, each CI job downloads ~60 MB. On a busy runner with intermittent network errors, that's a regular source of spurious failures.

---

## Test fixtures

Centralise repeated object construction in helpers, not in individual tests:

```go
func widgetFixture(name, ns string, replicas int32) *appsv1.Widget {
    return &appsv1.Widget{
        ObjectMeta: metav1.ObjectMeta{
            Name:      name,
            Namespace: ns,
        },
        Spec: appsv1.WidgetSpec{
            Replicas: replicas,
            Image:    "nginx:1.27-alpine",
        },
    }
}
```

For envtest tests, pair fixtures with cleanup:

```go
func createWidget(t *testing.T, w *appsv1.Widget) {
    t.Helper()
    require.NoError(t, k8sClient.Create(ctx, w))
    t.Cleanup(func() {
        _ = k8sClient.Delete(ctx, w)
    })
}
```

`t.Cleanup` runs even if the test panics, which means the envtest API server doesn't accumulate stale objects that interfere with later tests. This matters more than it sounds — a Widget from `TestA` that a Reconcile loop is still processing will cause `TestB`'s `Eventually` to time out if the names collide.

---

## Coverage

```bash
go test ./... -coverprofile=coverage.out
go tool cover -html=coverage.out      # annotated per-line in a browser
go tool cover -func=coverage.out | tail -1  # total percentage
```

Chase coverage on the reconciler's core happy path, the deletion/finalizer path, and the degraded-status path. Don't chase 100% — covering every early-return in `cmd/main.go` startup is low return. A reasonable gate:

```yaml
- run: |
    go tool cover -func=coverage.out | awk \
      '/total:/ { if ($3 + 0 < 80) { print "Coverage below 80%: " $3; exit 1 } }'
```

Always run tests with `-race`:

```bash
go test ./... -race
```

The race detector has near-zero false positives. It catches real concurrency bugs — shared maps, counters modified from multiple goroutines — that only appear under load in production. The cost is ~2× slower test execution, which is worth every millisecond.

---

## Debugging Testing

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Tests pass locally, fail in CI with `no kind is registered for the type` | Scheme setup doesn't register all types; a locally cached binary has an older scheme | Add `AddToScheme` for every type the reconciler touches; run `go clean -testcache && go test ./...` locally to reproduce |
| `envtest.Start()` fails with `unable to find binary` in CI | `KUBEBUILDER_ASSETS` not set or binaries not downloaded on the CI runner | Add `setup-envtest use` as a step and export `KUBEBUILDER_ASSETS`; cache `~/.local/share/kubebuilder-envtest/` |
| Reconciler test is flaky — `Deployment not found` roughly half the time | Race between reconciler goroutine and test assertion; `require.NoError` + `client.Get` immediately after `Reconcile()` call | Switch to `gomega.Eventually`; the reconciler goroutine may not have completed yet |
| `r.Status().Update()` in fake client test updates nothing silently | `WithStatusSubresource()` missing from `fake.NewClientBuilder()` | Add `.WithStatusSubresource(&appsv1.Widget{})` to the builder |
| Race detector reports data race in reconciler | Concurrent map access — commonly a package-level `map` used in tests or a shared counter | Replace with `sync.Map` or protect with `sync.Mutex`; never share mutable state across goroutines without synchronisation |
| `go test` hangs and never exits | Goroutine leak — `mgr.Start(ctx)` called but the context is never cancelled | Pass a context with `t.Cleanup(cancel)` or a `cancel` called in `TestMain` so the manager shuts down when tests finish |
| envtest test suite takes 3+ minutes in CI | envtest binaries downloaded on every run (no cache) | Cache `~/.local/share/kubebuilder-envtest/` in CI; assert `KUBEBUILDER_ASSETS` is non-empty at the top of the test |

> **War story.** Our operator's envtest suite was failing intermittently in CI with the cryptic message `failed to start envtest: unable to start control plane: timed out waiting for process kube-apiserver to start`. It passed locally every time. After 2 hours of investigation, we found that the CI runner's `/tmp` partition was 100% full — a previous job had left behind gigabytes of log files. The envtest binaries couldn't write their socket file to `/tmp`. The failure looked like a download problem, a binary corruption problem, a timeout problem — it was a disk problem. The two commands that would have found it in two minutes: `df -h /tmp` and `ls -lhS /tmp | head -20`. Always check environment preconditions before assuming your code is broken.

---

## Checkpoint

You're ready to test controllers when you can, without looking it up:

1. Write a table-driven test with three named cases for a pure function that maps a `WidgetSpec` to an expected Deployment replica count.
2. Explain the difference between `assert` and `require` in testify and give a concrete example where using `assert` when you needed `require` hides a real bug.
3. Build a fake client pre-populated with a Widget, call `Reconcile()`, and assert the resulting Deployment has the expected replica count.
4. Explain what `WithStatusSubresource()` does and describe the failure mode when it's absent.
5. Write an envtest `TestMain` that starts the API server, registers the controller, and shuts everything down cleanly.
6. Explain why `gomega.Eventually` is the right assertion tool for post-reconcile state in envtest, and what a `time.Sleep(2 * time.Second)` alternative costs you.
7. Show the two commands to download envtest binaries and run the test suite with race detection.
8. Diagnose a goroutine leak where `go test` never exits — what is the root cause and the fix?

➡ Next up: **Packaging & Deploying the Operator** — a distroless Docker image, RBAC manifests, kind load, and Kustomize/Helm packaging.
