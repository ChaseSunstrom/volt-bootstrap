// comptime for over a runtime tuple evaluates the tuple expression once, not once per element
use std::io;

var calls: i32 = 0;

fn make() -> (i32, bool, i32) {
    calls += 1;
    return (1, true, 3);
}

fn main() -> void {
    comptime for (x) in make() {
        std::println(x);
    }
    std::println("calls {}", calls);
}
// expect: 1
// expect: true
// expect: 3
// expect: calls 1
