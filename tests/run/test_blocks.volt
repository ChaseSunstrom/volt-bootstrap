// flags: --test
// test blocks: `test "name" { ... }` items, run under --test instead of main, each through
// std::testing::run (a line per test, a count, exit 1 when one fails); the body is a -> !void fn
use std::io;
use std::testing;

fn add(a: i32, b: i32) -> i32 {
    return a + b;
}

error lookup_error { MISSING }

fn find(k: i32) -> lookup_error!i32 {
    if (k < 0) {
        return lookup_error::MISSING;
    }
    return k;
}

fn main() -> void {
    std::println("main doesn't run under --test");
}

test "adds" {
    try std::testing::assert_eq(add(2, 2), 4);
    try std::testing::assert_eq(add(-1, 1), 0, "opposites");
}

test "fails on purpose" {
    try std::testing::assert_eq(add(2, 2), 5);
}

test "an error ends it" {
    val n = try find(-1);
    std::println("not here {}", n);
}

namespace inner {
    test "in a namespace" {
        try std::testing::assert(true);
    }
}

// `test` is still a name
fn test(x: i32) -> i32 {
    return x;
}
// expect: test adds ... ok
// expect: test fails on purpose ... FAILED
// expect: test an error ends it ... FAILED (MISSING)
// expect: test in a namespace ... ok
// expect: 2 passed, 2 failed
// exit: 1
