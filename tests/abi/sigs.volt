// each shape the C ABIs pass differently, through an export fn; tests/abi.rs compares how voltc
// lowers these with how clang lowers sigs.c's, for each host
struct s1 { a: u8; }
struct s3 { a: u8; b: u8; c: u8; }
struct s4 { a: i16; b: u8; }
struct s8 { a: i32; b: i32; }
struct s12 { a: i32; b: i32; c: i32; }
struct s16 { a: i64; b: i64; }
struct s24 { a: i64; b: i64; c: i64; }
struct hd2 { x: f64; y: f64; }
struct hf3 { x: f32; y: f32; z: f32; }
struct hd4 { a: f64; b: f64; c: f64; d: f64; }
struct hd5 { a: f64; b: f64; c: f64; d: f64; e: f64; }
struct pair { a: f32; b: f32; }
struct nest { p: pair; c: f32[2]; }
struct mix { f: f32; i: i32; }
struct al16 { a: i128; }
struct fd { a: f32; b: f64; }
struct hd1 { x: f64; }
struct hh2 { a: f16; b: f16; }
struct hq2 { a: f128; b: f128; }
struct hhf { a: f16; b: f32; }
struct hh3 { a: f16; b: f16; c: f16; }
struct hhi { a: f16; b: i32; }
struct hq1 { x: f128; }

struct hdh { a: f64; b: f16; }
struct hhd { a: f16; b: f64; }
struct hih { a: i64; b: f16; }
struct hhd2 { a: f16; b: f16; c: f64; }
struct hdh2 { a: f64; b: f16; c: f16; }
export fn fhdh(x: hdh) -> hdh { return x; }
export fn fhhd(x: hhd) -> hhd { return x; }
export fn fhih(x: hih) -> hih { return x; }
export fn fhhd2(x: hhd2) -> hhd2 { return x; }
export fn fhdh2(x: hdh2) -> hdh2 { return x; }
export fn fhhf(x: hhf) -> hhf { return x; }
export fn fhh3(x: hh3) -> hh3 { return x; }
export fn fhhi(x: hhi) -> hhi { return x; }
export fn fhq1(x: hq1) -> hq1 { return x; }
export fn f1(x: s1) -> s1 { return x; }
export fn f3(x: s3) -> s3 { return x; }
export fn f4(x: s4) -> s4 { return x; }
export fn f8(x: s8) -> s8 { return x; }
export fn f12(x: s12) -> s12 { return x; }
export fn f16(x: s16) -> s16 { return x; }
export fn f24(x: s24) -> s24 { return x; }
export fn fh1(x: hd1) -> hd1 { return x; }
export fn fhh2(x: hh2) -> hh2 { return x; }
export fn fhq2(x: hq2) -> hq2 { return x; }
export fn fh2(x: hd2) -> hd2 { return x; }
export fn fh3(x: hf3) -> hf3 { return x; }
export fn fh4(x: hd4) -> hd4 { return x; }
export fn fh5(x: hd5) -> hd5 { return x; }
export fn fnest(x: nest) -> nest { return x; }
export fn fmix(x: mix) -> mix { return x; }
export fn fal16(x: al16) -> al16 { return x; }
export fn ffd(x: fd) -> fd { return x; }
export fn ints(a: i8, b: u16, c: i32, d: i64) -> i8 { return a; }
export fn wide(a: i128) -> i128 { return a; }
export fn floats(a: f32, b: f64) -> f32 { return a; }
export fn edge(a: i64, b: i64, c: i64, w: i128, x: s16) -> void {}
export fn many(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, x: s12, d1: f64, d2: f64, d3: f64, d4: f64, d5: f64, d6: f64, d7: f64, h: hf3, n: nest, big: s24) -> void {}

fn main() -> void {}
