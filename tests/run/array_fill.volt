use std::io;
// {} is an all-zero array (what a var without an initializer holds) and {x; n} is n copies of x,
// with x evaluated once: in locals, struct field defaults, globals, comptime and T[].

struct packet {
    head: u8[4] = { 0xAB; 4 };
    body: u8[64] = {};
    len: usize = 0;
}

val TABLE: i32[8] = { -1; 8 };
val MAYBE: u8[2]? = { 4; 2 };
val ORIGIN: packet = {};

<T: type>
fn triple(x: T) -> T[3] {
    return { x; 3 };
}

var calls = 0;

fn next() -> i32 {
    calls += 1;
    return calls * 10;
}

comptime fn sum(xs: i32[5]) -> i32 {
    var s = 0;
    for (x) in xs {
        s += x;
    }
    return s;
}

fn main() -> void {
    val p: packet = {};
    std::println("{} {} {} {}", p.head[0], p.head[3], p.body[63], p.len);
    var zs: f64[3] = {};
    zs[1] = 2.5;
    std::println("{} {} {}", zs[0], zs[1], zs[2]);
    val xs: i32[4] = { next(); 4 };
    std::println("{} {} {}", xs[0], xs[3], calls);
    val ys: u16[] = { 7; 5 };
    std::println("{} {}", ys.len, ys[4]);
    std::println("{} {}", TABLE[0], TABLE[7]);
    comptime val total = sum({ 3; 5 });
    std::println("{}", total);
    val grid: u8[2][3] = { { 1; 2 }; 3 };
    std::println("{} {}", grid[2][1], grid.len);
    val maybe: i32[2]? = { 9; 2 };
    std::println("{}", (maybe ?? { 0; 2 })[1]);
    val none: i32[0] = { next(); 0 };
    std::println("{} {}", none.len, calls);
    std::println("{} {} {}", (MAYBE ?? { 0; 2 })[1], ORIGIN.head[2], triple(2.5)[2]);
}
// expect: 171 171 0 0
// expect: 0 2.5 0
// expect: 10 10 1
// expect: 5 7
// expect: -1 -1
// expect: 15
// expect: 1 3
// expect: 9
// expect: 0 2
// expect: 4 171 2.5
