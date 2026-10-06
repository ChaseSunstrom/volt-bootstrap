// @expand(expr) is expr, and reports what it became as a note at compile time: a comptime value,
// or the generic instance a call runs. voltc expand FILE[:LINE] and the editor's hover show the
// same, and what comptime if, the fns a comptime fn declared and @derive did
use std::io;

@attributes([@derive(eq)])
struct point {
    x: i32;
    y: f64;
}

comptime fn getter(T: type) -> void {
    attach fn get_x(this: T&) -> i32 {
        return this.x;
    }
}

comptime getter(point);

comptime fn greeting() -> str {
    return "hi";
}

<T: type>
fn twice(v: T) -> T {
    return v + v;
}

fn main() -> void {
    val n = @expand(@sizeof(point) * 2);
    val t = @expand(twice(21));
    val u = @expand(twice(@cast<i64>(twice(21))));
    val w = @expand(t + 1);
    val g = greeting();
    val h = @expand(greeting());
    comptime match (@sizeof(point)) {
        16 => { std::print("{} {} ", w, g == h); },
        default => {},
    }
    comptime for (i) in 0..3 {
        std::print(i);
    }
    std::print(" ");
    val p: point = { x: 4, y: 0.5 };
    comptime if (@sizeof(point) == 16) {
        std::println("{} {} {} {} {}", n, t, u, p.get_x(), p == p);
    }
}
// expect: 43 true 012 32 42 84 4 true
// expect-stderr: expands to 32 (usize)
// expect-stderr: expands to a call of twice<i32>(v: i32) -> i32
// expect-stderr: expands to a call of twice<i64>(v: i64) -> i64
// expect-stderr: expands to a value of type i32
// expect-stderr: expands to "hi" (str)
