---
title: Safety checks
description: What debug builds check, what release builds drop, and the exit codes.
sidebar:
  order: 17
---

Debug builds (the default) check the mistakes C leaves undefined, and stop the program with a
message and exit code 101:

| Check | Example |
| --- | --- |
| integer overflow | `i32` max `+ 1` |
| division by zero | `x / y` or `x % y` with `y` 0 |
| shifting too far | `x << n` on an `i32` with `n` 32 or more |
| out-of-bounds indexing | `xs[10]` on a 3-element array |
| unwrapping null | `*p` on a null pointer, `.value` on an empty optional |
| unwrapping an error | `.value` on an error union holding an error |
| reading another variant's payload | `s.CIRCLE` when `s` holds a `SQUARE` |
| double free | deleting the same memory twice through a bad `@cast`, `@read` or C code |
| freeing with the wrong size | `a.free<T>(p, n)` with another `n` than the block was allocated with |
| resuming a finished frame | `resume f` after the [async](/volt-bootstrap/guide/async/) fn returned, or `await f` twice |
| `@panic` | always |

```volt
use std::io;
// exit: 101

fn main() -> void {
    val xs: i32[] = { 1, 2, 3 };
    var i = 0;
    while (true) {
        std::println(xs[i]);   // traps when i reaches 3
        i++;
    }
}
```

The message names the place: `app.volt:8:22: panic: index 3 out of bounds (len 3)`.

## Release builds

`--release` (bolt: `--release` or a profile with `optimize = true`) builds with optimization and
without most of these checks: integer arithmetic wraps, a division by zero isn't caught, and a
shift by at least the type's width shifts by the amount modulo the width. What would read memory as
the wrong thing stays checked: indexing and slicing, reading a payload of the variant a value
doesn't hold, and `.value` on a null optional or an error union holding an error. Each is one
compare and a trap instruction: no call and no message, so a bare-metal build still makes no hidden
calls. A failed check stops the program with a signal (SIGILL on x86-64, SIGTRAP on arm64), and
output still buffered is lost, as with C's `abort`; run the debug build to see where. A finished
frame resumed or awaited again, and `@panic`, still stop with their message. A function with
`@attributes([@unchecked])` has no bounds checks in its body, for a hot loop known to stay in range.
Code that wants wrapping in every mode uses `+%`, `-%` and `*%`.

The optimizer removes a check it can prove passes, such as `xs[i]` in `for (i) in 0..xs.len` over a
slice or array (that loop then vectorizes as it would in C), so most loops pay nothing. Over the
[benchmarks](/volt-bootstrap/internals/benchmarks/), the checks release keeps cost under 3%
(geomean, LLVM backend), paid by code that indexes with values it computes: a bytecode interpreter's
stack pointer costs it the most, 1.7x its unchecked time. std skips the check in a few internals
where the index is in range by construction: sifting a heap, filling a `vec` in `resize`, and
writing a number's digits.

## Leaks

`--leak-check` makes a debug build count allocations: if any is still live when the program ends,
it exits with code 102.

## What the compiler checks

Some mistakes never compile: using a moved value, moving inside a loop without a new value before
the next pass, copying a type with a `delete` hook but no `copy` hook, a `match` that misses a case,
a null `T&`, writing through a reference to a
[`val`](/volt-bootstrap/guide/references/#references-to-a-val), a statement that computes a value
and drops it (`x == 1;`; a call's result may be dropped), and format strings that don't match their
arguments.

## What the compiler warns about

Some mistakes with references are warnings: the program still builds, and the warning says what to
change. Volt has no lifetimes to write and no borrow errors; it looks at each function on its own.

- **A view used after its container changed.** A slice, `str`, reference or iterator a method gave
  out of a local container (`xs.items()`, `name.as_str()`, `m.get(k)`) looks into the container's
  storage. A call that may move or free that storage (`push`, `insert`, `reserve`, `append`,
  `clear`, `remove` and the like, marked `@invalidates` in std) leaves the view looking at what
  may be gone:

  ```volt ignore
  val s = xs.items();
  xs.push(2) catch @panic("out of memory");
  std::println(s.len);   // warning: 's' looks into 'xs', whose items may have moved or been
                         // freed since: get 's' again after the change
  ```

  A read on any path after the change warns, a loop's next pass included. Changing a container
  inside a `for` loop over its items (`for (y) in xs.items()`, `this.a.b.items()`, or straight
  over a C++ container, `for (y) in this.v`) warns at the change, a new value for it or for a
  container it's a field of (`this.a = ...`) included: the loop goes on over the old items. A
  loop over a copy, a range or an array (read through its place each round) doesn't.
  The container may be a local, a parameter or a field of one (`this.items.items()`): a change to
  `this.items`, or to `this` as a whole, reaches the views into it, and one to `this.b` leaves a
  view of `this.a` alone. Giving the container a new value (`xs = ys`, `this.items = ...`,
  `*this = other`) is a change too when the old value had something to delete; a field written
  (`xs.n = 2`), plain data given a new value and a reference pointed elsewhere aren't. A closure held in a local
  and called by its name is followed both ways: one that captured a view warns where it's called
  after the view's container changed, and one whose body changes a container it captured
  (`|xs&| () { xs.push(1) ... }`) makes that change at each call. What isn't followed: the same
  container reached through another name (`val r = &this.items; r.push(1)`), and a closure
  stored in a field, returned, passed to a function or captured by another closure that calls it.
- **A reference to a local, returned in a value.** Returning `&n` itself, or a literal holding it,
  is an error. Returning a local that holds a reference to one of the function's own locals (a
  struct with `{ x: &n }`, a `v.x = &n`, a pointer `val r = &n`) warns: what it refers to is gone
  once the function returns.
