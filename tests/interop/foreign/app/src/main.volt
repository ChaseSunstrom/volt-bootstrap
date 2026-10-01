use std::io;
// a Volt program using a Rust crate and a Zig file: bolt builds both and writes their C headers
use { "rs_geom.h" } as rs;
use { "zig_math.h" } as zig;

extern "C" fn twice(x: i32) -> i32 {
    return x * 2;
}

fn main() -> void {
    val a: rs::Point = { x: 0.0, y: 0.0 };
    var b: rs::Point = { x: 3.0, y: -4.0 };
    std::println("dist {} quadrant {}", rs::rg_dist(a, b), rs::rg_quadrant(&b));
    rs::rg_scale(&b, 2.0);
    std::println("scaled {} {}", b.x, b.y);
    val text = "héllo";
    std::println("chars {} apply {}", rs::rg_count_chars(@cast<u8*>(text.ptr), text.len), rs::rg_apply(twice, 21));
    var r: zig::Range = { lo: 0, hi: 10 };
    std::println("clamp {} {}", zig::zm_clamp(42, r), zig::zm_clamp(-5, r));
    val xs: i64[4] = { 1, 2, 3, 4 };
    std::println("sum {}", zig::zm_sum(&xs[0], 4));
    zig::zm_widen(&r, 5);
    std::println("widened {} {}", r.lo, r.hi);
}
