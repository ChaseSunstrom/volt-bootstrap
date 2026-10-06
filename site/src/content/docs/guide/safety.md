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
| out-of-bounds indexing | `xs[10]` on a 3-element array |
| unwrapping null | `*p` on a null pointer, `.value` on an empty optional |
| unwrapping an error | `.value` on an error union holding an error |
| reading another variant's payload | `s.CIRCLE` when `s` holds a `SQUARE` |
| double free | deleting the same memory twice through a bad `@read` or C code |
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

The message names the place: `app.volt:7:22: panic: index 3 out of bounds (len 3)`.

## Release builds

`--release` (bolt: `--release` or a profile with `optimize = true`) builds with optimization and
without most of these checks: integer arithmetic wraps, and a shift by at least the type's width
shifts by the amount modulo the width. What would read memory as the wrong thing stays checked:
indexing and slicing, reading a payload of the variant a value doesn't hold, and `.value` on a null
optional or an error union holding an error. Each is one compare and a trap instruction: no call and
no message, so a bare-metal build still makes no hidden calls. A failed check stops the program with
a signal (SIGILL on x86-64), and output still buffered is lost, as with C's `abort`; run the debug
build to see where. A function with `@attributes([@unchecked])` has no bounds checks in its body,
for a hot loop known to stay in range. Code that wants wrapping in every mode uses `+%`, `-%` and
`*%`.

The optimizer removes a check it can prove passes, such as `xs[i]` in `for (i) in 0..xs.len` over a
slice or array (that loop then vectorizes as it would in C), so most loops pay nothing. Over the
[benchmarks](/volt-bootstrap/internals/benchmarks/), the checks release keeps cost under 3%
(geomean, LLVM backend), paid by code that indexes with values it computes: a bytecode interpreter's
stack pointer costs it the most, 1.6x its unchecked time. std skips the check in a few internals
where the index is in range by construction: sifting a heap, and writing a number's digits.

## Leaks

`--leak-check` makes a debug build count allocations: if any is still live when the program ends,
it exits with code 102.

## What the compiler checks

Some mistakes never compile: using a moved value, moving inside a loop without a new value before
the next pass, copying a type with a `delete` hook but no `copy` hook, a `match` that misses a case,
a null `T&`, an unhandled `E!T` (it has to be `try`'d, `catch`'d or kept as a value), and format
strings that don't match their arguments.

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
  inside a `for` loop over its items warns at the change: the loop goes on over the old items.
  What isn't followed yet: a field's container (`this.items.items()`), only a local's or a
  parameter's; giving the container a new value (`xs = ys`); and views used inside closures.
- **A reference to a local, returned in a value.** Returning `&n` itself, or a literal holding it,
  is an error. Returning a local that holds a reference to one of the function's own locals (a
  struct with `{ x: &n }`, a `v.x = &n`, a pointer `val r = &n`) warns: what it refers to is gone
  once the function returns.
