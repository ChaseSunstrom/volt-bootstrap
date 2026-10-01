use std::io;
// every C typedef is a type name: integers, pointers, function pointers, a struct's second name
use { "c_typedefs.h" } as c;

fn mul(a: i32, b: i32) -> i32 {
    return a * b;
}

fn main() -> void {
    val n: c::big = c::times(1 << 20, 1 << 20);
    var t: c::tally = { n: 1 };
    val r: c::counter_ref = &t;
    c::bump(r);
    c::bump(&t);
    val f: c::binop = mul;
    val k: c::calc = { op: c::pick(1), scale: 3 };
    val s: c::size_t = 5;
    std::println("{} {} {}", n, t.n, (f ?? return)(6, 7));
    std::println("{} {}", (k.op ?? return)(2, 3) * @cast<i32>(k.scale), s);
}

// expect: 1099511627776 3 42
// expect: 15 5
