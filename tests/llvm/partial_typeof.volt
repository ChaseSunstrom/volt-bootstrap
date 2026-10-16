// a C struct with a field of a type Volt can't read (__typeof__): like partial_struct.volt, libclang
// gives its layout, and passing it by value takes a C shim (C knows the field's type), so both
// backends build it (tests/selfhost.rs checks both)
use std::io;
use { "partial_struct.h" } as c;

fn main() -> void {
    val x: c::typed = { a: 1, b: 4 };
    std::println("{}", c::typed_b(x));
}
