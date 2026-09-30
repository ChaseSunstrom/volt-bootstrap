use std::io;
// Volt calls a Rust staticlib (tests/interop/rust_lib.rs) and hands it a callback
extern "C" fn rs_triple(x: i32) -> i32;
extern "C" fn rs_apply(f: extern "C" fn(i32) -> i32, x: i32) -> i32;

extern "C" fn plus_one(x: i32) -> i32 {
    return x + 1;
}

fn main() -> void {
    std::println("rust {} {}", rs_triple(3), rs_apply(plus_one, 7));
}
