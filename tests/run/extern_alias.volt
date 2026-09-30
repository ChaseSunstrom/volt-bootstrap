use std::io;
use { "string.h" } as c;
// our own view of memmove (void* where the header says const void*): no clash with string.h
extern "C" fn memmove(dst: void*, src: void*, n: usize) -> void*;
fn main() -> void {
    var a: u8[4] = { 1, 2, 3, 4 };
    memmove(&a[1], &a[0], 3);
    std::println(a);
    std::println(c::strlen("four"));
}
// expect: { 1, 1, 2, 3 }
// expect: 4
