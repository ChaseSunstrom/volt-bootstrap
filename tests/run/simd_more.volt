use std::io;
use std::simd;
// std::simd vectors compare (== when every lane is equal: a NaN lane makes == false and != true, as
// a NaN float does), shift lane by lane (by a vector of amounts or one amount; >> is arithmetic on
// signed lanes), print as their lanes do (a format spec applies to each), are made at comptime, and
// std::simd::lanes_eq gives the lanes' equality one by one

fn ramp() -> std::simd::i32x4 {
    var v: std::simd::i32x4 = {};
    for (i) in 0..4 {
        v[i] = @cast<i32>(i) * 10;
    }
    return v;
}

fn main() -> void {
    val a: std::simd::f32x4 = { 1.0, 2.0, 3.0, 4.0 };
    val b: std::simd::f32x4 = { 1.0, 2.0, 3.0, 4.0 };
    val c: std::simd::f32x4 = { 1.0, 2.0, 3.5, 4.0 };
    std::println("{} {} {} {}", a == b, a != b, a == c, a != c);
    val z: f32 = 0.0;
    val n: std::simd::f32x4 = { 1.0, z / z, 3.0, 4.0 };
    std::println("{} {}", n == n, n != n);
    val p: std::simd::i32x8 = { 1, 2, 3, 4, 5, 6, 7, 8 };
    var q = p;
    std::println("{}", p == q);
    q[7] = 9;
    std::println("{} {}", p == q, p != q);
    val s: std::simd::i32x4 = { 1, -8, 256, -1 };
    val by: std::simd::i32x4 = { 0, 1, 4, 31 };
    val l = s << by;
    val r = s >> by;
    std::println("{} {} {} {}", l[0], l[1], l[2], l[3]);
    std::println("{} {} {} {}", r[0], r[1], r[2], r[3]);
    val k = s << 2;
    std::println("{} {} {} {}", k[0], k[1], k[2], k[3]);
    val u = std::simd::splat<std::simd::u8x16>(200);
    val ur = u >> 3;
    std::println("{} {}", ur[0], ur[15]);
    std::println("{}", a);
    std::println("{:.2}", c);
    std::println("{}", p);
    comptime val m = ramp();
    std::println("{} {}", m, m == ramp());
    std::println("{}", std::simd::lanes_eq(a, c));
}
// expect: true false false true
// expect: false true
// expect: true
// expect: false true
// expect: 1 -16 4096 -2147483648
// expect: 1 -4 16 -1
// expect: 4 -32 1024 -4
// expect: 25 25
// expect: { 1, 2, 3, 4 }
// expect: { 1.00, 2.00, 3.50, 4.00 }
// expect: { 1, 2, 3, 4, 5, 6, 7, 8 }
// expect: { 0, 10, 20, 30 } true
// expect: { true, true, false, true }
