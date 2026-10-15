// every f128 operation, the same through LLVM and C (tests/golden.rs f128_soft_c runs it with C's
// soft quad path too): arithmetic, negation, compares (NaN's too), conversions both ways, and f128
// in globals, arrays, optionals and structs
use std::io;

val G: f128 = 2.5;
val GN: f128 = -1.5;
val GC: f128 = @cast<f128>(2.0);
val GI: f128 = @cast<f128>(7);
var V: f128 = -4;
// initializers C has to take as constants: the soft path folds them to bits
val THIRD: f128 = 1.0 / 3.0;
val GG: f128 = 2.5 * -2.0 + 1.0;
val GNC: f128 = -@cast<f128>(2.0);
val GR: f128 = GNC;

struct holder { q: f128; n: i32; }

fn zero() -> f128 { return 0.0; }
fn d(x: f128) -> f64 { return @cast<f64>(x); }
fn sign(x: f128) -> u128 { return @bitcast<u128>(x) >> 127; }

fn main() -> void {
    std::println("{} {} {} {} {}", d(G), d(GN), d(GC), d(GI), d(V));
    V += G;
    std::println("{} {} {} {} {}", d(V), d(THIRD * 3.0), d(GG), d(GNC), d(GR));
    // arithmetic and compound assignment
    var x: f128 = 3;
    x += 1.5;
    x -= 0.25;
    x *= G;
    x /= 2.0;
    std::println("{} {} {}", d(x), d(x % 2.0), d(@cast<f128>(7.5) % 2.0));
    // negation, -0.0
    val nz = -zero();
    val nzl: f128 = -0.0;
    std::println("{} {} {} {} {}", d(-x), d(nz), sign(nz), sign(nzl), nz == zero());
    // compares
    val one: f128 = 1.0;
    std::println("{} {} {} {} {} {}", x == 5.3125, x != 5.3125, x <= 5.3125, x >= 6.0, x < one, x > one);
    std::println("{} {} {} {} {} {}", one == one, one != one, one <= one, one >= one, one < one, one > one);
    val nan = zero() / zero();
    std::println("{} {} {} {} {} {}", nan == nan, nan != nan, nan < one, nan <= one, nan > one, nan >= one);
    // conversions to f128 and back
    val a: i8 = -100;
    val b: u8 = 200;
    val c: i16 = -30000;
    val e: u16 = 60000;
    val f: i32 = -2000000000;
    val g: u32 = 4000000000;
    val h: i64 = -9000000000000000000;
    val i: u64 = 18000000000000000000;
    val j: i128 = -1267650600228229401496703205376;
    val k: u128 = 1329227995784915872903807060280344576;
    std::println("{} {} {} {} {}", @cast<i8>(@cast<f128>(a)), @cast<u8>(@cast<f128>(b)), @cast<i16>(@cast<f128>(c)), @cast<u16>(@cast<f128>(e)), @cast<i32>(@cast<f128>(f)));
    std::println("{} {} {} {} {}", @cast<u32>(@cast<f128>(g)), @cast<i64>(@cast<f128>(h)), @cast<u64>(@cast<f128>(i)), @cast<i128>(@cast<f128>(j)), @cast<u128>(@cast<f128>(k)));
    val hf: f16 = 1.5;
    val sf: f32 = 0.1;
    val df: f64 = 0.1;
    std::println("{} {} {} {}", @cast<f16>(@cast<f128>(hf)), @cast<f32>(@cast<f128>(sf)), @cast<f64>(@cast<f128>(df)), d(@cast<f128>(true)));
    val m: f128 = -100.75;
    val p: f128 = 250.5;
    std::println("{} {} {} {} {} {}", @cast<i8>(m), @cast<u8>(p), @cast<i16>(m), @cast<u16>(p), @cast<i32>(m), @cast<u32>(p));
    std::println("{} {} {} {} {} {}", @cast<i64>(m), @cast<u64>(p), @cast<i128>(m), @cast<u128>(p), @cast<bool>(m), @cast<bool>(zero()));
    std::println("{} {} {}", @cast<f16>(m), @cast<f32>(m), @cast<f64>(m));
    // arrays, optionals, struct fields
    var arr: f128[2] = { 1.25, 2.0 };
    arr[1] += arr[0];
    val o: f128? = arr[1];
    val none: f128? = null;
    var s: holder = { q: 0.5, n: 3 };
    s.q *= @cast<f128>(s.n);
    std::println("{} {} {} {}", d(arr[1]), d(o ?? 0.0), d(none ?? -1.0), d(s.q));
}
// expect: 2.5 -1.5 2 7 -4
// expect: -1.5 1 -4 -2 -2
// expect: 5.3125 1.3125 1.5
// expect: -5.3125 -0 1 1 true
// expect: true false true false false true
// expect: true false true true false false
// expect: false true false false false false
// expect: -100 200 -30000 60000 -2000000000
// expect: 4000000000 -9000000000000000000 18000000000000000000 -1267650600228229401496703205376 1329227995784915872903807060280344576
// expect: 1.5 0.1 0.1 1
// expect: -100 250 -100 250 -100 250
// expect: -100 250 -100 250 true false
// expect: -100.75 -100.75 -100.75
// expect: 3.25 3.25 -1 1.5
