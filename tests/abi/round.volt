// C and Volt calling each other with each shape AAPCS64 passes differently (tests/abi.rs runs it
// under qemu-aarch64 with harness.c): harness.c calls the v_ fns, and volt_calls_c calls its c_ fns.
// Every fn hands its shape back with each field one more
struct s3 { a: u8; b: u8; c: u8; }
struct s12 { a: i32; b: i32; c: i32; }
struct s16 { a: i64; b: i64; }
struct s24 { a: i64; b: i64; c: i64; }
struct hf3 { x: f32; y: f32; z: f32; }
struct hd4 { a: f64; b: f64; c: f64; d: f64; }
struct pair { a: f32; b: f32; }
struct nest { p: pair; c: f32[2]; }
struct mix { f: f32; i: i32; }
struct al16 { a: i128; }

extern "C" fn c_s3(x: s3) -> s3;
extern "C" fn c_s12(x: s12) -> s12;
extern "C" fn c_s16(x: s16) -> s16;
extern "C" fn c_s24(x: s24) -> s24;
extern "C" fn c_hf3(x: hf3) -> hf3;
extern "C" fn c_hd4(x: hd4) -> hd4;
extern "C" fn c_nest(x: nest) -> nest;
extern "C" fn c_mix(x: mix) -> mix;
extern "C" fn c_al16(x: al16) -> al16;
extern "C" fn c_ints(a: i8, b: u16) -> i32;
extern "C" fn c_many(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, x: s12, d1: f64, d2: f64, d3: f64, d4: f64, d5: f64, d6: f64, d7: f64, d8: f64, y: hf3, n: nest, big: s24) -> f64;

export fn v_s3(x: s3) -> s3 { return { a: x.a + 1, b: x.b + 1, c: x.c + 1 }; }
export fn v_s12(x: s12) -> s12 { return { a: x.a + 1, b: x.b + 1, c: x.c + 1 }; }
export fn v_s16(x: s16) -> s16 { return { a: x.a + 1, b: x.b + 1 }; }
export fn v_s24(x: s24) -> s24 { return { a: x.a + 1, b: x.b + 1, c: x.c + 1 }; }
export fn v_hf3(x: hf3) -> hf3 { return { x: x.x + 1.0, y: x.y + 1.0, z: x.z + 1.0 }; }
export fn v_hd4(x: hd4) -> hd4 { return { a: x.a + 1.0, b: x.b + 1.0, c: x.c + 1.0, d: x.d + 1.0 }; }
export fn v_nest(x: nest) -> nest { return { p: { a: x.p.a + 1.0, b: x.p.b + 1.0 }, c: { x.c[0] + 1.0, x.c[1] + 1.0 } }; }
export fn v_mix(x: mix) -> mix { return { f: x.f + 1.0, i: x.i + 1 }; }
export fn v_al16(x: al16) -> al16 { return { a: x.a + 1 }; }
export fn v_ints(a: i8, b: u16) -> i32 { return @cast<i32>(a) * 100000 + @cast<i32>(b); }

// past the registers: the s12 after eight ints, and the HFAs after eight doubles, go on the stack
export fn v_many(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, x: s12, d1: f64, d2: f64, d3: f64, d4: f64, d5: f64, d6: f64, d7: f64, d8: f64, y: hf3, n: nest, big: s24) -> f64 {
    val ints = a + b + c + d + e + f + g + h + @cast<i64>(x.a + x.b + x.c) + big.a + big.b + big.c;
    val fls = d1 + d2 + d3 + d4 + d5 + d6 + d7 + d8 + @cast<f64>(y.x + y.y + y.z + n.p.a + n.p.b + n.c[0] + n.c[1]);
    return @cast<f64>(ints) * 1000.0 + fls;
}

// harness.c's fns from Volt: the number that came back wrong
export fn volt_calls_c() -> i32 {
    var bad: i32 = 0;
    val a = c_s3({ a: 1, b: 2, c: 3 });
    if (a.a != 2 || a.b != 3 || a.c != 4) { bad += 1; }
    val b = c_s12({ a: 1, b: 2, c: 3 });
    if (b.a != 2 || b.b != 3 || b.c != 4) { bad += 1; }
    val c = c_s16({ a: 1, b: 2 });
    if (c.a != 2 || c.b != 3) { bad += 1; }
    val d = c_s24({ a: 1, b: 2, c: 3 });
    if (d.a != 2 || d.b != 3 || d.c != 4) { bad += 1; }
    val e = c_hf3({ x: 1.5, y: 2.5, z: 3.5 });
    if (e.x != 2.5 || e.y != 3.5 || e.z != 4.5) { bad += 1; }
    val f = c_hd4({ a: 1.5, b: 2.5, c: 3.5, d: 4.5 });
    if (f.a != 2.5 || f.b != 3.5 || f.c != 4.5 || f.d != 5.5) { bad += 1; }
    val g = c_nest({ p: { a: 1.5, b: 2.5 }, c: { 3.5, 4.5 } });
    if (g.p.a != 2.5 || g.p.b != 3.5 || g.c[0] != 4.5 || g.c[1] != 5.5) { bad += 1; }
    val h = c_mix({ f: 1.5, i: 2 });
    if (h.f != 2.5 || h.i != 3) { bad += 1; }
    val big = (@cast<i128>(1) << 100) + 5;
    val i = c_al16({ a: big });
    if (i.a != big + 1) { bad += 1; }
    if (c_ints(-3, 65535) != -234465) { bad += 1; }
    val m = c_many(1, 2, 3, 4, 5, 6, 7, 8, { a: 9, b: 10, c: 11 }, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, { x: 0.25, y: 0.5, z: 0.75 }, { p: { a: 1.0, b: 2.0 }, c: { 3.0, 4.0 } }, { a: 12, b: 13, c: 14 });
    if (m != 105043.5) { bad += 1; }
    return bad;
}

fn main() -> void {}
