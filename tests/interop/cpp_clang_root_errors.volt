// after a clang-typed @cpp with no C++ import (cpp_typed_by_clang's C++ context, in this file's own
// namespace), this file is still not a C++ import's: a generic of its own lent a val's std::string
// isn't made again with the string read-only (ro_text_inst), so grow's one error is the caller's,
// and a cpp_error of its own isn't one for @cpp<E!R> (cpp_error_ns). Both follow the @cpp in main
// (a fn above main is checked before it)
use std::io;

error cpp_error {
    BAD,
}

<T: type>
fn grow(s: T&) -> void {
    s.push('!');
}

fn main() -> void {
    val two = @cpp("{0} + 1", 1);
    val s = std::string::from("hi");
    grow(&s);
    val n = @cpp<cpp_error!i32>("{0} + 2", 1) catch |e| { return; };
    std::println("{} {} {}", two, s, n);
}
