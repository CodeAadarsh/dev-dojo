# Errors, Modules & Tooling

> **Module 03 · Course 22** — Go's error handling is honest to the point of being verbose, and that honesty is exactly what makes large codebases maintainable. This module covers the error model precisely — sentinel errors, typed errors, wrapping, the ways engineers accidentally discard failure information — along with the module system and the tooling layer that keeps quality high without relying on discipline alone.

---

## The error Interface

`error` is a built-in interface with one method:

```go
type error interface {
    Error() string
}
```

Any type with an `Error() string` method satisfies it. Errors are ordinary values — you return them, store them, pass them around, and check them the same way you handle any other value. The language gives them no special status beyond the convention that functions return `error` as their last value.

```go
func divide(a, b float64) (float64, error) {
    if b == 0 {
        return 0, errors.New("divide by zero")
    }
    return a / b, nil
}
```

Convention: multiple return values, error last, check at the call site. The compiler will not warn about an unchecked error return — that's what linters are for, and they are non-optional.

---

## Sentinel Errors

A sentinel error is a package-level `var` that is the canonical signal for a specific condition. The standard library uses them extensively: `io.EOF`, `sql.ErrNoRows`, `http.ErrNoCookie`.

```go
var ErrNotFound = errors.New("not found")
var ErrPermission = errors.New("permission denied")
```

Callers compare with `errors.Is`, not `==`:

```go
if errors.Is(err, ErrNotFound) {
    // handle the specific condition
}
```

`errors.Is` unwraps the error chain. `==` only works on the outermost error value; it breaks the moment any wrapping is applied. Use `errors.Is` everywhere.

**When to use sentinels:** simple, well-known conditions where callers only need to know *which* condition occurred, not additional data. `io.EOF` is the canonical example — the caller needs to know the stream ended, not how many bytes were available.

---

## Typed Errors

A typed error is a concrete struct that implements the `error` interface and carries structured data:

```go
type ValidationError struct {
    Field   string
    Message string
}

func (e *ValidationError) Error() string {
    return fmt.Sprintf("validation: field %q: %s", e.Field, e.Message)
}
```

Callers use `errors.As` to extract the concrete type and inspect its fields:

```go
var ve *ValidationError
if errors.As(err, &ve) {
    fmt.Println("bad field:", ve.Field)
}
```

`errors.As` unwraps the chain until it finds a value assignable to the target type. It is the correct tool when the caller needs to inspect the error's data, not just its identity.

**Sentinel vs typed error:**

| Use a sentinel | Use a typed error |
|---|---|
| Callers only check which condition, not associated data | Callers need structured data from the error |
| Condition is stable across versions | Error carries per-occurrence context that varies |
| You want a minimal public API surface | A public struct is acceptable |

---

## Error Wrapping with %w

`fmt.Errorf` with the `%w` verb wraps an error, forming a chain that `errors.Is` and `errors.As` can traverse:

```go
func fetchUser(id int) (*User, error) {
    u, err := db.Query(id)
    if err != nil {
        return nil, fmt.Errorf("fetchUser id=%d: %w", id, err)
    }
    return u, nil
}
```

The returned error's `Error()` string includes the context. `errors.Is(err, originalErr)` is still true because `%w` embeds the original in the chain. `errors.Unwrap(err)` returns the next error in the chain.

**Wrapping rules:**

1. Add context that names *where* the error happened and which input triggered it.
2. Do not re-wrap at every layer with the same information — one wrapping per function boundary is enough.
3. Use `%w` if callers upstream need to inspect the underlying error; use `%v` if you want to erase the inner error's identity from the chain (this prevents `errors.Is` matching the inner sentinel).

**The swallowed error (wrong):**

```go
u, err := db.Query(id)
if err != nil {
    log.Println("query failed") // logged but not returned
    return nil, nil             // caller sees no error — the failure is invisible
}
```

This is the most common mistake in Go error handling. Every error check up the call stack now passes. Log *and* return, or return *without* logging and let the caller decide what to log:

```go
if err != nil {
    return nil, fmt.Errorf("db.Query id=%d: %w", id, err)
}
```

---

## panic and recover

`panic` is for programming errors — nil dereferences, index out of bounds, type assertion failures, broken invariants that should never occur in correct code. It is not Go's exception mechanism for expected failures.

```go
// wrong — using panic for expected control flow
func getUser(id int) *User {
    u, ok := store[id]
    if !ok {
        panic("user not found") // should return (nil, ErrNotFound)
    }
    return u
}
```

`recover` catches a panic in a deferred function. Use it at process boundaries (HTTP handler, goroutine entry point) to turn a panic into an error log and graceful degradation:

```go
func safeHandler(w http.ResponseWriter, r *http.Request) {
    defer func() {
        if rc := recover(); rc != nil {
            log.Printf("panic recovered: %v\n%s", rc, debug.Stack())
            http.Error(w, "internal server error", http.StatusInternalServerError)
        }
    }()
    doBusinessLogic(w, r)
}
```

`controller-runtime` already wraps each reconcile invocation in a panic recovery — you do not need to add your own inside a reconciler.

---

## Go Modules and Versioning

A Go module is the unit of versioning and distribution, declared in `go.mod`:

```
module github.com/myorg/myoperator

go 1.22
```

**Key commands:**

```bash
go get github.com/some/dep@v1.2.3   # pin a dependency to an exact version
go get github.com/some/dep@latest   # update to the latest tagged version
go mod tidy                          # add missing, remove unused entries from go.mod and go.sum
go mod vendor                        # copy all dependencies into vendor/ (for air-gapped builds)
go mod why github.com/some/dep       # explain why a package is required (transitive dependency graph)
go mod graph | grep some/dep         # visualise the full dependency graph for a module
```

**Minimum Version Selection (MVS).** Go resolves dependency versions deterministically: it picks the *minimum* version that satisfies all direct and indirect requirements. This is reproducible without a separate lockfile because `go.sum` records cryptographic hashes of every module version used. Contrast with npm's "latest compatible" strategy, which can pull in a different version on each `install`. With MVS, a build is reproducible on any machine that has network access to the module proxy.

Consequence: when you run `go get dep@latest`, you raise the floor. When another module later requires a higher version of a shared dependency, your build automatically picks up that higher version — without your intervention. `go mod tidy` keeps `go.mod` and `go.sum` consistent with the current import graph.

**Major version breaks.** A module's v2+ is treated as a distinct module path: `github.com/foo/bar/v2`. Importing `v1` and `v2` of the same package in the same binary is legal. This is why you can depend on `k8s.io/client-go` and `sigs.k8s.io/controller-runtime` without conflict — they have their own versioned paths.

---

## go test: Table Tests and Benchmarks

**Table-driven tests** are idiomatic Go:

```go
func TestDivide(t *testing.T) {
    cases := []struct {
        name    string
        a, b    float64
        want    float64
        wantErr bool
    }{
        {"positive", 10, 2, 5, false},
        {"zero divisor", 10, 0, 0, true},
        {"negative", -9, 3, -3, false},
    }
    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            got, err := divide(tc.a, tc.b)
            if (err != nil) != tc.wantErr {
                t.Fatalf("divide(%v,%v) error=%v wantErr=%v", tc.a, tc.b, err, tc.wantErr)
            }
            if !tc.wantErr && got != tc.want {
                t.Errorf("divide(%v,%v) = %v, want %v", tc.a, tc.b, got, tc.want)
            }
        })
    }
}
```

`t.Run` creates a named sub-test per case. Run one specific case: `go test -run TestDivide/zero_divisor`. Use `t.Fatal` (stops the sub-test) rather than `t.Error` (continues) when a failure makes subsequent assertions meaningless.

`t.Helper()` marks a function as a helper so test failures report the caller's line, not the helper's:

```go
func requireNoError(t *testing.T, err error) {
    t.Helper()
    if err != nil {
        t.Fatalf("unexpected error: %v", err)
    }
}
```

**Benchmarks:**

```go
func BenchmarkDivide(b *testing.B) {
    for i := 0; i < b.N; i++ {
        divide(10, 3)
    }
}
```

Run with: `go test -bench=. -benchmem ./...`

`-benchmem` adds allocations per operation — critical for cloud-native code where GC pressure under load matters. A benchmark that shows `0 allocs/op` for a hot path is a meaningful win.

Use `b.ResetTimer()` after expensive setup so setup time isn't included in the measured loop. Compare two implementations with `benchcmp` or `benchstat` from `golang.org/x/perf`.

---

## go vet, staticcheck, golangci-lint

**go vet** is included in the toolchain. It catches common mistakes the compiler allows:

```bash
go vet ./...
```

What it catches: mismatched `Printf` format verbs (`%s` on an int), unreachable code, using a mutex after it has been copied, `sync.WaitGroup` race between `Add` and `Wait`, composited lock values.

**staticcheck** (`honnef.co/go/tools`) goes deeper: unused exports, deprecated API use, incorrect `errors.As` target types, unnecessary nil checks, and more:

```bash
go install honnef.co/go/tools/cmd/staticcheck@latest
staticcheck ./...
```

**golangci-lint** is the meta-linter that runs vet + staticcheck + dozens of other linters in parallel. Configure via `.golangci.yml`:

```yaml
linters:
  enable:
    - errcheck      # unchecked error returns
    - nilerr        # returning a typed nil via the error interface (the nil != nil trap)
    - govet         # built-in vet checks
    - staticcheck   # staticcheck SA checks
    - exhaustive    # switch exhaustiveness on enum types
    - revive        # stylistic issues (replaces golint)
    - gosec         # security-oriented checks
```

Run in CI:

```bash
golangci-lint run --timeout 5m ./...
```

Add `nilerr` to your config immediately — it catches the `interface nil != nil` bug from Module 01 mechanically, before the code reaches review.

---

## Project Layout

There is no enforced Go project layout, but a widely-used convention has emerged for Kubernetes operators:

```
myoperator/
├── cmd/
│   └── main.go              # entry point — thin: flags, config, wiring; no business logic
├── internal/
│   ├── controller/          # reconcilers (inaccessible outside this module — Go enforces this)
│   ├── api/
│   │   └── v1alpha1/        # CRD types: types.go, groupversion_info.go, zz_generated.deepcopy.go
│   └── metrics/             # Prometheus collectors, instrument wrappers
├── config/                  # kustomize manifests: RBAC, CRD, Deployment, Namespace
│   ├── crd/
│   ├── rbac/
│   └── default/
├── go.mod
├── go.sum
└── Makefile                 # build, generate, lint, test, docker-build targets
```

`internal/` is enforced at the compiler level — code outside the module that tries to import an `internal` package gets a compile error. Use it for everything not intended as a public API. `cmd/` stays thin: parse flags, load config, wire up the `controller-runtime` Manager, call `mgr.Start`. All real logic lives in `internal/`.

This layout mirrors what `operator-sdk init` and `kubebuilder init` scaffold for you. Following it means tooling works out of the box.

---

## Debugging Errors, Modules & Tooling

| Symptom | Likely cause | Fix |
|---|---|---|
| Error returned but callers never enter error-handling branches | Error swallowed at an intermediate layer — logged then `return nil, nil` | Enable `errcheck` linter; audit every `if err != nil` block — every one must either return the error or consciously ignore it with `//nolint:errcheck` and a comment |
| `errors.Is(err, SomeVar)` returns false even though the message looks right | Error was wrapped with `%v` not `%w`; chain is broken | Use `%w`; verify the chain in a test with `errors.Unwrap(err)` |
| `go mod tidy` pulls in an unexpectedly old version of a package | Another dependency requires a lower minimum; MVS picks the lowest satisfying version | `go mod why <module>` to find the transitive path; `go get <module>@latest` to raise the floor |
| `cannot use x.T as y.T` for the same package at two different major versions | Two dependencies import different major versions of the same module | Align all dependencies on the same major version; use `go mod graph \| grep <module>` to identify the conflicting requirement |
| Test passes locally, fails intermittently in CI | Flaky test — external dependency, map iteration order, test state leakage | Run `go test -shuffle=on -count=5 ./...`; mock I/O dependencies; use `t.Cleanup` to isolate state between sub-tests |
| `go test -race` is clean but production has a data corruption report | Race exists in a code path the test suite never exercises | Add `-race` to integration and load tests in CI; run the race-instrumented binary in staging |

> **War story.** After a dependency upgrade in the SAP usage-api service, `go mod tidy` silently pulled in a transitive version of `client-go` one minor below what our controller required. The build succeeded — MVS picked the minimum. At runtime, a field added in the newer `client-go` was absent, so reconciles read a zero value for the retry budget. The symptom was a sudden spike in reconcile rate: retry budget 0 means every transient API error retried immediately, saturating the API server. Diagnosis took two hours because the binary logged no error — it was a silent zero value. The fix was `go get sigs.k8s.io/controller-runtime@latest`, which pulled the correct transitive `client-go`. The prevention: we added `go mod tidy && git diff --exit-code go.sum` as a CI step — any unrecorded dependency change fails the build before it ships.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Implement a typed error that carries a field name and a message; show a caller using `errors.As` to extract and print the field name.
2. Explain the difference between `%w` and `%v` in `fmt.Errorf`, and name a scenario where you'd choose `%v` deliberately.
3. Describe MVS in one sentence and explain why it produces a more reproducible build than "latest compatible" resolution strategies.
4. Write a table-driven test with `t.Run` for a function with two inputs and a boolean error expectation.
5. Name the linter that catches unchecked error returns, and the one that catches the typed-nil-returned-as-error bug.
6. Explain the compiler-enforced rule about `internal/` packages and describe what belongs in `cmd/` vs `internal/` in an operator project.
7. Explain why `go mod tidy && git diff --exit-code go.sum` belongs in every CI pipeline.

➡ Next up: **client-go & controller-runtime** — wire a real Kubernetes controller from first principles.
