// a failing std::testing assertion says where it was called (FILE:LINE:COL: assertion failed ...), so a
// test with several says which one failed
use std::io;

fn main() -> void {
    std::testing::assert(1 + 1 == 2) catch |e| {};
    std::testing::assert(1 + 1 == 3) catch |e| {};
    std::testing::assert_eq(2, 3, "sums") catch |e| {};
    std::testing::assert_ne(4, 4) catch |e| {};
    std::testing::assert_near(1.0, 2.0, 0.5) catch |e| {};
    std::println("done");
}
// expect: done
// expect-stderr: testing_location.volt:7:5: assertion failed
// expect-stderr: testing_location.volt:8:5: assertion failed: sums
// expect-stderr: testing_location.volt:9:5: assertion failed: left != right
// expect-stderr: testing_location.volt:10:5: assertion failed: left and right are further apart than 0.5
// reject-stderr: testing_location.volt:6:
