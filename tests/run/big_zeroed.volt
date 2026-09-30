// A big array declared without a value is zero-filled (LLVM: by memset, not one huge store)
use std::io;

struct page {
    head: u32;
    bytes: u8[65536];
}

fn main() -> void {
    var buf: u8[65536];
    buf[65535] = 7;
    var p: page;
    p.head = 1;
    p.bytes[100] = 2;
    std::println("{} {} {} {}", buf[0], buf[65535], p.bytes[99], p.bytes[100]);
}
// expect: 0 7 0 2
