// catch owns the error it catches: an error with a payload that needs delete is deleted when the
// handler ends, whether it's bound (|e|) or not, and when the handler leaves early
use std::io;

struct res { n: i32; }
attach fn delete(this: res&) -> void { std::println("delete {}", this.n); }

error oops { BAD: res }

fn fail(n: i32) -> oops!i32 {
    return oops::BAD({ n: n });
}

fn leave_early() -> void {
    val x = fail(3) catch |e| {
        std::println("leaving");
        return;
    };
    std::println("unreachable {}", x);
}

fn main() -> void {
    val a = fail(1) catch 0;
    val b = fail(2) catch |e| 5;
    std::println("{} {}", a, b);
    leave_early();
}
// expect: delete 1
// expect: delete 2
// expect: 0 5
// expect: leaving
// expect: delete 3
