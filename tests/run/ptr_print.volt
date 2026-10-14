// a pointer prints as 0x and lowercase hex, null as null
// expect: 0x1000
// expect: null
// expect: 0xdeadbeef
use std::io;

fn main() -> i32 {
    val p = @cast<i32*>(4096);
    val n: i32* = null;
    std::println("{}", p);
    std::println("{}", n);
    std::println("{}", @cast<i32*>(0xdeadbeef));
    return 0;
}
