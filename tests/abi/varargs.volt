// tests/abi.rs win_arm64_varargs: aggregates and floats passed to a C varargs function
struct hd2 { x: f64; y: f64; }
struct hd4 { a: f64; b: f64; c: f64; d: f64; }
struct hf3 { x: f32; y: f32; z: f32; }

extern "C" fn va_sink(n: i32, ...) -> void;

export fn call_va(a: hd2, b: hd4, c: hf3, f: f32, d: f64) -> void {
    va_sink(5, a, b, c, f, d);
}

fn main() -> void {}
