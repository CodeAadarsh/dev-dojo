# Solution — Go Fundamentals: WordFreq + Generics

Complete `basics.go`. Copy this in, then run the verifier.

```go
package basics

import "strings"

// WordFreq counts tokens after splitting on whitespace and lower-casing.
func WordFreq(s string) map[string]int {
	counts := make(map[string]int)
	for _, word := range strings.Fields(s) {
		counts[strings.ToLower(word)]++
	}
	return counts
}

// Map applies f to every element of in and returns the results in order.
func Map[T, U any](in []T, f func(T) U) []U {
	out := make([]U, len(in))
	for i, v := range in {
		out[i] = f(v)
	}
	return out
}

// Filter returns elements of in for which keep is true.
func Filter[T any](in []T, keep func(T) bool) []T {
	out := make([]T, 0, len(in))
	for _, v := range in {
		if keep(v) {
			out = append(out, v)
		}
	}
	return out
}
```

## Why each piece is correct

**`strings.Fields(s)`** splits on any run of Unicode whitespace and returns an
empty slice (not nil) for an empty or all-whitespace input. This handles leading
spaces, trailing spaces, and multiple consecutive spaces in one call — no
`strings.Split` + `strings.TrimSpace` loop required.

**`strings.ToLower(word)`** handles the case-fold requirement. For production
Unicode text you'd use `strings.ToLower` with `unicode.ToLower` for each rune;
for ASCII input (which `WordFreq` is defined over here) `strings.ToLower` is
correct and fast.

**`make(map[string]int)`** — not `var counts map[string]int`. An uninitialized
map is nil; a write to a nil map panics. `make` allocates the underlying hash
table. Reading from a nil map (returning the zero value) does NOT panic, which
is why the bug is subtle: `WordFreq` on an empty string would return nil without
the explicit `make`, and `len(nil_map) == 0`, so naive callers wouldn't notice.
The harness tests for an empty-but-non-nil map explicitly.

**`Map` uses `make([]U, len(in))`** so the returned slice has exactly the right
length and all positions are pre-zeroed. Index assignment (`out[i] = f(v)`)
rather than `append` avoids reallocations when `len(in)` is known upfront.

**`Filter` uses `make([]T, 0, len(in))`** — length 0, capacity `len(in)`. Worst
case (all elements match), `append` never reallocates. The explicit `0` length
means `len(out) == 0` for an empty result, giving the non-nil empty slice the
harness requires. `nil` would satisfy `len(out) == 0` too, but callers that JSON-
encode the result would get `null` instead of `[]` — an important distinction in
REST APIs.

## Generic type parameters — how the compiler sees them

```go
Map[T, U any](in []T, f func(T) U) []U
```

`T` and `U` are inferred at call sites:

```go
Map([]int{1, 2, 3}, func(n int) int { return n * 2 })
// T=int, U=int — inferred, no explicit brackets needed

Map([]string{"go"}, strings.ToUpper)
// T=string, U=string — inferred from func signature

Map([]Job{...}, func(j Job) Result { ... })
// T=Job, U=Result — zero runtime overhead vs a hand-written loop
```

The `any` constraint means no methods are required on `T` or `U`. If you needed
to call `.String()` on `T` inside `f`, you'd write `[T fmt.Stringer, U any]`.

## Production angle

In a real service, `Map` and `Filter` live in a `slices` or `functional`
internal package, but since Go 1.21 the standard library ships
`slices.Index`, `slices.Contains`, and `maps.Keys`. Go 1.23 adds range-over-func
iterators. If you're on 1.21+ in production, check `slices` and `maps` packages
before rolling your own — the stdlib versions have SSA-optimised hot paths.
