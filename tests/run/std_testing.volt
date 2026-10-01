// flags: --leak-check
use std::io;
use std::testing;
// std::testing's assertions print what failed with both values and return FAILED; run() goes on
// to the next test, reports each one and gives the exit code

struct point {
    x: i32;
    y: i32;
}

// a type's own eq is what assert_eq compares with
attach fn eq(this: point&, other: point&) -> bool {
    return this.x == other.x && this.y == other.y;
}

fn passes() -> !void {
    try std::testing::assert(1 < 2, "order");
    try std::testing::assert_eq(2 + 2, 4);
    try std::testing::assert_eq("volt", "volt", "names");
    try std::testing::assert_ne(1.5, 2.5);
    try std::testing::assert_near(0.1 + 0.2, 0.3, 1e-12);
    val inf = 1.0 / 0.0;
    try std::testing::assert_near(inf, inf, 0.0, "infinity");
    val a: point = { x: 1, y: 2 };
    val b: point = { x: 1, y: 2 };
    try std::testing::assert_eq(a, b);
}

fn unequal() -> !void {
    val a: point = { x: 1, y: 2 };
    val b: point = { x: 1, y: 3 };
    try std::testing::assert_eq(a, b, "points");
    std::println("not reached");
}

fn far() -> !void {
    try std::testing::assert_near(3.0, 3.25, 0.1);
}

fn not_a_number() -> !void {
    val nan = 0.0 / 0.0;
    try std::testing::assert_near(nan, nan, 1.0);
}

fn false_check() -> !void {
    try std::testing::assert(false);
}

fn same() -> !void {
    try std::testing::assert_ne("a", "a", "letters");
}

error io_like { CLOSED }

fn other_error() -> !void {
    return io_like::CLOSED;
}

fn main() -> i32 {
    val tests: std::testing::test[] = {
        { name: "passes", body: passes },
        { name: "unequal", body: unequal },
        { name: "far", body: far },
        { name: "not_a_number", body: not_a_number },
        { name: "false_check", body: false_check },
        { name: "same", body: same },
        { name: "other_error", body: other_error },
    };
    return std::testing::run(tests[..]);
}
// expect: test passes ... ok
// expect: test unequal ... FAILED
// expect: test far ... FAILED
// expect: test not_a_number ... FAILED
// expect: test false_check ... FAILED
// expect: test same ... FAILED
// expect: test other_error ... FAILED (CLOSED)
// expect: 1 passed, 6 failed
// exit: 1
// expect-stderr: assertion failed: points
// expect-stderr:   left:  point { x: 1, y: 2 }
// expect-stderr:   right: point { x: 1, y: 3 }
// expect-stderr: assertion failed: left and right are further apart than 0.1
// expect-stderr:   left:  3
// expect-stderr:   right: 3.25
// expect-stderr: assertion failed
// expect-stderr: assertion failed: letters: left != right
// expect-stderr:   both:  a
