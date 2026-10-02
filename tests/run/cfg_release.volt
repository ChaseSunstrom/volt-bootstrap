use std::io;
// @cfg("release") is true in an optimized build (--release), false otherwise
// flags: --release

fn main() -> void {
    std::println("{}", @cfg("release"));
}
// expect: true
