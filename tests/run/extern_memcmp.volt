// a program's own extern of a C function std uses (memcmp, behind str ==), with its own signature
use std::io;

extern "C" fn memcmp(a: u8*, b: u8*, n: usize) -> i32;

fn main() -> void {
    val a: str = "xy";
    std::println("{} {}", a == "xy", memcmp(@cast<u8*>(a.ptr), @cast<u8*>("xz".ptr), 2) < 0);
}
// expect: true true
