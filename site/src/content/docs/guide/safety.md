---
title: Safety checks
description: What debug builds check, what release builds drop, and the exit codes.
sidebar:
  order: 16
---

Debug builds (the default) check the mistakes C leaves undefined, and stop the program with a
message and exit code 101:

| Check | Example |
| --- | --- |
| integer overflow | `i32` max `+ 1` |
| out-of-bounds indexing | `xs[10]` on a 3-element array |
| unwrapping null | `*p` on a null pointer, `.value` on an empty optional |
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
without these checks: integer arithmetic wraps, a shift by at least the type's width shifts by the
amount modulo the width, and indexing isn't checked. Code that wants
wrapping in every mode uses `+%`, `-%` and `*%`.

## Leaks

`--leak-check` makes a debug build count allocations: if any is still live when the program ends,
it exits with code 102.

## What the compiler checks

Some mistakes never compile: using a moved value, moving inside a loop without a new value before
the next pass, copying a type with a `delete` hook but no `copy` hook, a `match` that misses a case,
a null `T&`, an unhandled `E!T` (it has to be `try`'d, `catch`'d or kept as a value), and format
strings that don't match their arguments.
