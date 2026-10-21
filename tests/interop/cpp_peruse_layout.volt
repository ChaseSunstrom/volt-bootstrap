// Volt types holding i64 and f64 (8-aligned on x86-64, 4-aligned in i386's C) mirrored for a C++
// template: each mirror checks its size and alignment against the target's C layout of the type
use std::io;
use { "cpp_peruse_layout.hpp" } as cpp;

struct point { x: i32; y: f64; }
struct span { a: u8; n: i64; tag: (i16, f64); }
enum shape { DOT, LINE: i64, BOX: point }

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
}
