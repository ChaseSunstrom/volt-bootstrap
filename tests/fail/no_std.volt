// flags: --no-std
// error: unknown name 'std'
use std::io;
fn main() -> void { std::println("x"); }
