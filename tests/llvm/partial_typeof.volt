// a C struct with a field of a type Volt can't read (__typeof__): like partial_struct.volt, the C
// backend compiles it and the LLVM backend refuses it (tests/selfhost.rs checks both)
use std::io;
use { "partial_struct.h" } as c;

fn main() -> void {
    val x: c::typed = { a: 1, b: 4 };
    std::println("{}", c::typed_b(x));
}
