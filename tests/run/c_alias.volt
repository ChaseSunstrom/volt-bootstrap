// a #define that names a C variable under another name is that variable by the macro's name too
// (macOS's stdio.h reaches stderr that way), and it can be written through
use std::io;
use { "c_alias.h" } as c;

fn main() -> void {
    std::println("{}", c::c_alias_count);
    c::c_alias_count = 9;
    std::println("{} {}", c::c_alias_count, c::c_alias_real);
    std::println("{}", c::c_alias_hidden);
}
// expect: 7
// expect: 9 9
// expect: 5
