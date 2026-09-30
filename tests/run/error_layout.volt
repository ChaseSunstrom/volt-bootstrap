// the compile-time layout of error values matches the C one (an error code is a uint32_t): @sizeof
// in comptime code (the interpreter's layout) equals the distance between neighbouring array elements
use std::io;

error oops { BAD, WORSE }

<T: type>
fn stride() -> usize {
    var a: T[2];
    return @cast<usize>(&a[1]) - @cast<usize>(&a[0]);
}

fn main() -> void {
    comptime val e = @sizeof(error);
    comptime val eu = @sizeof(error!u8);
    comptime val o = @sizeof(oops);
    comptime val ou = @sizeof(oops!u64);
    std::println("{} {}", e, stride<error>());
    std::println("{} {}", eu, stride<error!u8>());
    std::println("{} {}", o, stride<oops>());
    std::println("{} {}", ou, stride<oops!u64>());
}
// expect: 4 4
// expect: 8 8
// expect: 4 4
// expect: 16 16
