---
title: Tests, examples and benchmarks
description: tests/, examples/ and benches/, and how bolt runs them.
sidebar:
  order: 7
---

## Tests

Each `.volt` file (or subdirectory) in `tests/` is a program; `bolt test` builds them all with the
test profile and runs each one. A test passes when it exits with 0.

```volt
use std::io;

fn add(a: i32, b: i32) -> i32 { return a + b; }

fn main() -> i32 {
    if (add(2, 2) != 4) {
        std::eprintln("add is broken");
        return 1;
    }
    return 0;
}
```

A test uses the package's library like any other code (`app::name`), and can use
`[dev-dependencies]`. `bolt test FILTER` runs only the tests whose name contains FILTER, and
`--no-run` builds without running.

Debug checks are on in tests, so an overflow or an out-of-bounds index fails the test with a
message; a profile with `leak-check = true` fails leaking tests too.

## Examples

Programs in `examples/` are built by `bolt build --examples` and run with
`bolt run --example NAME`.

## Benchmarks

`bolt bench` builds the programs in `benches/` with the bench profile (optimized) and reports how
long each took. `bolt bench FILTER` picks some.
