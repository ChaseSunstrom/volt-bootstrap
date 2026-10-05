// flags: --test -- add
// a --test program's argument picks the tests whose names contain it
use std::io;
use std::testing;

test "adds" {
    try std::testing::assert_eq(1 + 1, 2);
}

test "adds more" {
    try std::testing::assert_eq(2 + 2, 4);
}

test "subtracts" {
    try std::testing::assert_eq(2 - 1, 1);
}
// expect: test adds ... ok
// expect: test adds more ... ok
// expect: 2 passed, 0 failed
