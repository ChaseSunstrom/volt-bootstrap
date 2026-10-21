// Volt types holding i64 and f64 (8-aligned on x86-64, 4-aligned in i386's C) mirrored for a C++
// template: each mirror checks its size and alignment against the target's C layout of the type
// (an @align(16) struct, an array member, and a tuple whose type name has quotes among them)
use std::io;
use { "cpp_peruse_layout.hpp" } as cpp;

struct point { x: i32; y: f64; }
struct span { a: u8; n: i64; tag: (i16, f64); }
enum shape { DOT, LINE: i64, BOX: point }
@attributes([@align(16)])
struct wide { a: i32; }
struct trio { ps: point[3]; n: i64; }

extern "C" fn plus_one(x: i32) -> i32 {
    return x + 1;
}

fn main() -> void {
    val p: point = { x: 3, y: 2.5 };
    val q = cpp::pul::echo(p);
    std::println("point {} {}", q.x, q.y);
    val s: span = { a: 7, n: 1 << 40, tag: (-2, 0.25) };
    val r = cpp::pul::echo(s);
    std::println("span {} {} {}", r.a, r.n, r.tag);
    match (cpp::pul::echo(shape::BOX(p))) {
        .BOX(b) => { std::println("shape {}", b.y); },
        default => { std::println("shape ?"); },
    }
    val o: f64? = 1.5;
    std::println("opt {}", cpp::pul::echo(o));
    val w: wide = { a: 9 };
    std::println("wide {} {}", cpp::pul::echo(w).a, @sizeof(wide));
    val tr: trio = { ps: { p, p, p }, n: 5 };
    val tq = cpp::pul::echo(tr);
    std::println("trio {} {} {} {}", tq.ps[0].y, tq.ps[1].y, tq.ps[2].y, tq.n);
    // a type whose name has quotes: extern "C" fn(i32) -> i32
    val ft: (extern "C" fn(i32) -> i32, i64) = (plus_one, 6);
    val fq = cpp::pul::echo(ft);
    val g = fq.0;
    std::println("fnptr {} {}", g(4), fq.1);
}
