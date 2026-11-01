# Go Fundamentals for Cloud-Native

> **Module 01 · Course 22** — Every Kubernetes operator, controller, and cloud-native CLI is written in Go. Before you wire informers or speak to the API server, you need to own the parts of the language that will trip you up in production: pointers, slices, interfaces, zero values, and the corner of the stdlib you'll actually reach for.

This is not an introduction to Go. It assumes you have written some Go before. It *is* a corrective — the parts that look obvious but behave in ways that surprise engineers coming from Java, Python, or TypeScript, and that surface as production bugs in controllers and operators.

---

## Values, Pointers, and Method Sets

Go passes values by copy. That single sentence explains most of the confusion in early Go code.

```go
type Config struct {
    Replicas int
    Image    string
}

func scaleUp(c Config) {
    c.Replicas++ // mutates the copy — the caller's value is unchanged
}

func scaleUpPtr(c *Config) {
    c.Replicas++ // mutates through the pointer — caller sees the change
}
```

**Pointer vs value receivers on methods:**

| Use a pointer receiver `(c *Config)` | Use a value receiver `(c Config)` |
|---|---|
| Method mutates the receiver | Method only reads |
| Struct is large (avoid copying) | Struct is small; immutable semantics desired |
| You need a nil check (`if c == nil`) | Zero-value is a valid, useful state |
| Any method already uses a pointer receiver (consistency rule) | — |

The consistency rule matters in cloud-native code. `controller-runtime` reconcilers are always registered as `*MyReconciler` because the runtime calls methods through an interface. If any method has a pointer receiver, the method set of the value type *T* does not include that method — only `*T`'s does. Mix receivers on the same type and the compiler may reject an interface assignment that looks like it should work:

```go
type Reconciler interface {
    Reconcile(ctx context.Context, req Request) (Result, error)
}

// ✓ pointer receiver — *MyReconciler satisfies Reconciler
func (r *MyReconciler) Reconcile(ctx context.Context, req Request) (Result, error) { ... }

// ✗ this value-receiver version only satisfies the interface for MyReconciler (not *MyReconciler)
//   if ANY other method uses a pointer receiver, *MyReconciler loses this method from its set
func (r MyReconciler) Reconcile(...) (...) { ... }
```

Nil pointer dereferences are runtime panics. The safe default is to return a pointer to a zero-value struct rather than `nil` when you want a ready-to-use default:

```go
cfg := &Config{}  // Replicas==0, Image==""; both zero values, safe to dereference
```

---

## Zero Values

Every variable in Go is initialised to its zero value when declared without an explicit value. This is a feature, not an omission.

| Type | Zero value |
|---|---|
| `int`, `float64` | `0` |
| `string` | `""` |
| `bool` | `false` |
| pointer, slice, map, channel, func, interface | `nil` |
| struct | all fields zero-initialised recursively |

Zero values let the standard library offer types that are usable without a constructor:

```go
var mu sync.Mutex     // zero-value Mutex is unlocked and ready — no New() needed
var wg sync.WaitGroup // same
var buf bytes.Buffer  // zero-value Buffer is empty and ready to Write into
```

You will see this pattern constantly in operator code: an empty struct with pointer fields is a valid, inert object as long as you check before dereferencing. The critical asymmetry between `nil` slice and `nil` map:

```go
var s []string          // nil slice — len(s)==0; append(s, "x") works fine
var m map[string]string // nil map — reads return zero value; writes PANIC

m["key"] = "value" // panic: assignment to entry in nil map
```

Always initialise maps explicitly:

```go
m := make(map[string]string)
// or
m := map[string]string{}
```

---

## Slices: The Aliasing Trap

Slices are the type most engineers think they understand and don't. A slice is a three-word header: a pointer to the underlying array, a length, and a capacity.

```
slice header:
  ptr  ──→  [ a ][ b ][ c ][ d ][ e ]   ← underlying array
  len = 3
  cap = 5
```

Two slices can share the same underlying array. Mutation through one is visible to the other:

```go
a := []int{1, 2, 3, 4, 5}
b := a[1:3]  // b shares the backing array; b == [2, 3]
b[0] = 99   // mutates a[1] — a is now [1, 99, 3, 4, 5]
```

The subtler trap: `append` may or may not create a new backing array depending on capacity.

```go
// cap not exceeded — SAME backing array
a := make([]int, 3, 5) // len=3, cap=5
b := a[:]
b = append(b, 4)  // fits within cap — b and a still share memory
b[0] = 99         // a[0] is now 99

// cap exceeded — NEW backing array
a2 := make([]int, 5, 5) // len=5, cap=5 — full
b2 := a2[:]
b2 = append(b2, 6) // new allocation; b2 detaches from a2
b2[0] = 99         // a2 is UNAFFECTED
```

This bites in controller code where you build a slice of status conditions, pass it to a helper that appends, and the helper silently mutates the caller's memory. **Defensive copy:**

```go
independent := append([]Status(nil), original...)
```

`append([]T(nil), src...)` is the idiomatic single-line copy of a slice.

---

## Structs and Maps

**Struct embedding** (not inheritance):

```go
type Meta struct {
    Name      string
    Namespace string
}

type Pod struct {
    Meta            // embedded — Pod.Name is promoted
    Spec PodSpec
}

p := Pod{Meta: Meta{Name: "worker-1"}}
fmt.Println(p.Name) // equivalent to p.Meta.Name
```

Embedding is how `controller-runtime` composes its types. `ctrl.Manager` embeds several interfaces so you get `mgr.GetClient()`, `mgr.GetScheme()`, `mgr.GetLogger()` directly on the manager value.

**Maps are reference types.** Passing a map to a function passes a reference; mutations inside the function are visible to the caller. Slices behave differently: the header (ptr + len + cap) is passed by value, so a reassignment `s = append(s, x)` inside a function is *not* visible to the caller unless the slice is returned or passed as `*[]T`.

```go
func addKey(m map[string]int) {
    m["added"] = 1  // caller sees this
}

func appendElem(s []int) {
    s = append(s, 99)  // caller does NOT see this if append allocates a new array
}
```

Map iteration has **non-deterministic order** in Go — this is guaranteed by the spec, not an accident. Sort the keys explicitly when ordering matters (canonical config strings, deterministic hashes for status conditions).

---

## Interfaces and Implicit Satisfaction

Go interfaces are satisfied implicitly: no `implements` keyword. If a type has all the methods listed in an interface, it satisfies it — without any declaration.

```go
type Patcher interface {
    Patch(ctx context.Context, obj client.Object, patch client.Patch, opts ...client.PatchOption) error
}
```

Any struct with that exact method signature satisfies `Patcher` without saying so. This makes testing trivial: write a struct with the required methods, assign it to the interface variable. No mocking framework needed.

**The `interface nil != nil` trap.** This is the most famous Go gotcha and the one engineers get wrong even after they know about it:

```go
type MyError struct{ msg string }

func (e *MyError) Error() string { return e.msg }

func mayFail(flag bool) error {
    var err *MyError = nil  // typed nil pointer
    if flag {
        err = &MyError{"boom"}
    }
    return err  // returns a non-nil interface wrapping a nil *MyError pointer!
}

func main() {
    err := mayFail(false)
    if err != nil {  // true — the interface has a type (*MyError) even though the value is nil
        fmt.Println("got error:", err)  // prints: got error: <nil>
    }
}
```

An interface value is `nil` only when **both** the type and the value fields are nil. Returning a typed nil pointer via an `error` interface sets the type field, making the interface non-nil even when the pointer is nil.

**Fix: return bare `nil` for the no-error path:**

```go
func mayFail(flag bool) error {
    if !flag {
        return nil  // untyped nil — interface type and value are both nil; == nil works
    }
    return &MyError{"boom"}
}
```

---

## The Stdlib You'll Actually Use

Cloud-native Go code reaches for a small set of packages constantly:

| Package | What it gives you |
|---|---|
| `context` | Cancellation, deadlines, request-scoped values — first argument to every I/O call |
| `fmt` | Formatting; `fmt.Errorf("%w", err)` for error wrapping |
| `errors` | `errors.Is`, `errors.As`, `errors.New`, `errors.Unwrap` |
| `io` | `io.Reader`, `io.Writer`, `io.EOF`, `io.Copy`, `io.ReadAll` |
| `os` | Env vars (`os.Getenv`), file I/O, `os.Exit` |
| `net/http` | HTTP client + server; use `http.Client` with a configured `Transport` |
| `encoding/json` | `json.Marshal`, `json.Unmarshal`; struct tags `json:"field,omitempty"` |
| `sync` | `sync.Mutex`, `sync.RWMutex`, `sync.WaitGroup`, `sync.Once` |
| `time` | `time.Duration`, `time.After`, `time.Sleep`, `time.Now()` |
| `log/slog` | Structured logging (Go 1.21+) — use instead of `fmt.Println` in service code |
| `testing` | `testing.T`, table tests, benchmarks, `t.Helper()` |

A note on `log/slog` vs the older `log` package: `slog` emits structured JSON, integrates with `context`, and supports log levels. Kubernetes controllers historically used `klog`; newer operators use `slog` or wrap it. Always thread `ctx` through every function that does I/O, even if you don't use it today — adding it later is a painful, pervasive refactor.

---

## Debugging Go Fundamentals

| Symptom | Likely cause | Fix |
|---|---|---|
| `assignment to entry in nil map` panic at runtime | Map declared with `var m map[K]V` and written before initialization | `m = make(map[K]V)` at declaration; add a nil-check guard before writes |
| Mutation in a helper is unexpectedly visible in the caller | Two slices share a backing array; the helper mutated in-place within capacity | Defensive copy before passing: `append([]T(nil), src...)` |
| `append` in a helper doesn't update the caller's slice | `append` returned a new slice header; the caller still holds the old one | Return the new slice from the helper, or pass `*[]T` |
| `err != nil` is true but `err.Error()` returns `<nil>` | Typed nil pointer returned via the `error` interface | Return bare `nil` instead of a named typed nil variable |
| Method call compiles but panics on nil receiver dereference | Pointer receiver method called on a nil `*T` without a nil guard | Add `if r == nil { return ... }` at the top of the method, or ensure the caller never passes nil |
| Interface comparison in a `switch` / `errors.Is` doesn't match | Wrapping broke the chain (`%v` not `%w`), or two different concrete types | Use `%w`; use `errors.Is`/`errors.As` not `==`; check the chain with `errors.Unwrap` in a test |

> **War story.** A controller at SAP was incorrectly treating a no-error path as an error. A helper returned `var e *apierrors.StatusError` and then hit a branch that returned early without ever assigning to `e`. At the call site: `if err != nil { return err }` — always true because `*apierrors.StatusError(nil)` wrapped in `error` is not nil. Production effect: every reconcile on the happy path logged a false error, fed our error-rate dashboard, and triggered a P2 alert at 3 AM. The fix was a two-word change — `return nil` instead of `return e`. Finding it required knowing the interface nil trap precisely. We added the `nilerr` rule to our `golangci-lint` config that same morning.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain why a value receiver method cannot mutate the original struct, and in what exact circumstance a value type does *not* satisfy an interface that only a pointer type satisfies.
2. List the three fields of a slice header and explain when `append` creates a new backing array versus reusing the existing one.
3. Write a defensive copy of a `[]string` in a single expression.
4. Explain the difference between a nil map and a nil slice, including which operations panic on each.
5. Describe the `interface nil != nil` trap: what exactly is being compared, and what is the one-line fix.
6. Name four packages from the stdlib that every cloud-native Go service uses, and state what each provides.
7. Write a zero-value struct that is immediately usable without a constructor call, and explain why this works.

➡ Next up: **Concurrency: Goroutines & Channels** — the communication patterns that make Go's concurrency model distinct.
