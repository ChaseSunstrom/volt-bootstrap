// flags: --backend c
// @cpp's {&0} for a C library function Volt declares its own way (snprintf with a u8* buffer, where
// the C headers C++ includes say char *): C++ reaches it by a name of its own, bound to the symbol
use std::io;
use { "cpp_fnaddr_libc.hpp" } as cpp;

extern "C" fn snprintf(b: u8*, n: usize, f: cstr, ...) -> i32;

fn main() -> void {
    var buf: u8[16] = {};
    val p: u8* = @cast<u8*>(&buf[0]);
    val n = @cpp<i32>("fill({&0}, {1}, {2}, {3})", snprintf, p, @cast<usize>(16), 42);
    std::println("{} {}", n, @cast<str>(@slice(&buf[0], @cast<usize>(n))));
}
// expect: 3 42!
