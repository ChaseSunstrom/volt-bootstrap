// a struct Volt can only partly read (a bitfield): libclang gives its layout, so both backends build it
use std::io;
use { "partial_struct.h" } as c;

fn main() -> void {
    val f: c::flags = { before: 1, after: 3 };
    std::println("{}", c::flags_after(f));
}
