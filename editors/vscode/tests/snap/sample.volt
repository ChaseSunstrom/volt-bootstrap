// A little of everything, for the grammar snapshot (tests/snap/sample.volt.snap)
use std::io;
use { "stdio.h" } as c;

/* shapes: a trait, two types that attach to it */
trait shape {
    fn area(this: Self&) -> f64;
}

struct circle { r: f64 = 1.0; }

attach shape -> circle {
    fn area(this: circle&) -> f64 { return 3.14159 * this.r * this.r; }
}

enum color: u8 { RED = 1, GREEN, BLUE, }

@attributes([@deprecated("use total")])
<T: type, N: usize>
fn sum(xs: T[N]) -> T {
    var s: T = 0;
    for (x) in xs {
        s += x;
    }
    return s;
}

async fn fetch(id: u32) -> str? {
    comptime val limit = 10;
    if (id > limit) {
        return null;
    }
    return "ok";
}

export fn volt_add(a: i32, b: i32) -> i32 {
    return a +% b;
}

fn main() -> void {
    val shapes: circle[2] = { { r: 2.0 }, {} };
    val n = @sizeof(circle);
    val f = fetch(3) ?? "none";
    c::printf("%d\n", 0b1010);
    std::println("{} {} {}", shapes[0].area(), n, f);
    match (color::RED) {
        .RED => { std::println("red"); },
        default => {},
    }
}
