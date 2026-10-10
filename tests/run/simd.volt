use std::io;
use std::simd;
// std::simd: vectors of numbers, lowered to SIMD registers: arithmetic between vectors of one type,
// negation, lanes read and written by index, { } literals, splat, sum, load and store, and a vector
// as a struct's field (aligned to its size, as C aligns one)

struct body {
    id: i32;
    pos: std::simd::f64x2;
}

fn main() -> void {
    val a: std::simd::f64x2 = { 1.5, 2.0 };
    val b: std::simd::f64x2 = { 0.5, 4.0 };
    val c = a + b;
    val d = a * b - c / b;
    std::println("{} {} {} {}", c[0], c[1], d[0], d[1]);
    val n = -d;
    std::println("{} {}", n[0], n[1]);
    var f = std::simd::splat<std::simd::f32x4>(2.5);
    f[2] = 1.0;
    f = f * f;
    std::println("{} {}", std::simd::sum(f), f[2]);
    val xs: i32[6] = { 1, 2, 3, 4, 5, 6 };
    var v = std::simd::load<std::simd::i32x4>(xs[1..5]);
    v = v * v + v;
    var out: i32[4] = { 0, 0, 0, 0 };
    std::simd::store(v, out[0..4]);
    std::println("{} {} {} {} {}", out[0], out[1], out[2], out[3], v[3] & 7);
    var bodies: std::vec<body> = {};
    bodies.push({ id: 1, pos: { 1.0, 2.0 } });
    bodies.push({ id: 2, pos: { 3.0, 4.0 } });
    var total = std::simd::splat<std::simd::f64x2>(0.0);
    for (x&) in bodies.items() {
        total = total + x.pos;
    }
    std::println("{} {} {} {}", total[0], total[1], @sizeof(body), @alignof(std::simd::f64x2));
    val k: usize = 3;
    std::println("{}", f[k]);
}
// expect: 2 6 -3.25 6.5
// expect: 3.25 -6.5
// expect: 19.75 1
// expect: 6 12 20 30 6
// expect: 4 6 32 16
// expect: 6.25
