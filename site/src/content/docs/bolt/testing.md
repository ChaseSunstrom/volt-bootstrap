---
title: Tests, examples and benchmarks
description: tests/, examples/ and benches/, and how bolt runs them.
sidebar:
  order: 7
---

## Tests

Each `.volt` file (or subdirectory) in `tests/` is a program; `bolt test` builds them all with the
test profile and runs each one. A test passes when it exits with 0.

`std::testing` has assertions that say what went wrong. One that fails prints to stderr why, with
the values it compared, and returns `FAILED`, so `try` ends the test there:
- `assert(ok, what)`.
- `assert_eq(left, right, what)` and `assert_ne(left, right, what)`. These compare with `eq`, so a
  type's own `eq` is used. They take their values by value, so an owned value such as a
  `std::string` moves in: pass `copy s`, or compare `s.as_str()`.
- `assert_near(left, right, tolerance, what)`, for floats. NaN is never near anything.

`what` is optional. `std::testing::run` takes a list of named test functions. It runs every one,
even after one fails, and prints `test NAME ... ok` or `... FAILED` for each, then a count. A test
that fails with some other error shows its name, as in `FAILED (NOT_FOUND)`. `run` returns the exit
code:

```volt
use std::io;
use std::testing;

fn add(a: i32, b: i32) -> i32 { return a + b; }

fn adds() -> !void {
    try std::testing::assert_eq(add(2, 2), 4);
    try std::testing::assert_eq(add(-1, 1), 0, "opposites");
}

fn averages() -> !void {
    try std::testing::assert_near((0.1 + 0.2) / 2.0, 0.15, 1e-12);
}

fn main() -> i32 {
    val tests: std::testing::test[] = {
        { name: "adds", body: adds },
        { name: "averages", body: averages },
    };
    return std::testing::run(tests[..]);
}
// expect: test adds ... ok
// expect: test averages ... ok
// expect: 2 passed, 0 failed
```

A test file can also be a plain `main() -> !void` that calls the assertions with `try`: the first
one that fails ends it with exit code 1.

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
