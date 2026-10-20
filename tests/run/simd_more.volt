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
    comptime val sq = ramp() * ramp() + (ramp() << 1);
    comptime val same = ramp() == ramp();
    comptime val differ = sq != ramp();
    std::println("{} {} {}", sq, same, differ);
    // narrow lanes, an f64 NaN lane, a compound shift, and a comptime shift wrapping as at run time
    val bytes: std::simd::vec(i8, 16) = { -128, -1, 64, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    val bl = bytes << 1;
    val br = bytes >> 2;
    std::println("{} {} {} {} {} {}", bl[0], bl[1], bl[2], br[0], br[1], br[15]);
    val zd: f64 = 0.0;
    val dn: std::simd::f64x2 = { zd / zd, 1.0 };
    std::println("{} {}", dn == dn, dn != dn);
    var acc = s;
    acc <<= 3;
    acc >>= by;
    std::println("{} {} {} {}", acc[0], acc[1], acc[2], acc[3]);
    comptime val cw = ramp() << 28;
    std::println("{} {}", cw, cw == (ramp() << 28));
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
// expect: { 0, 120, 440, 960 } true true
// expect: 0 -2 -128 -32 -1 0
// expect: false true
// expect: 8 -32 128 -1
// expect: { 0, -1610612736, 1073741824, -536870912 } true
