// a clang-typed @cpp with no C++ import (cpp_typed_by_clang's C++ context, in this file's own
// namespace) doesn't make Volt's own generics here C++ ones: id(&m) deduces a reference, which
// writes through, and a plain fn's name is a fn value, not a C function pointer
use std::io;

<T: type>
fn id(x: T) -> T {
    return x;
}

<T: type>
fn kind(x: T) -> str {
    return @typeinfo(T).short_name;
}

fn next(x: i32) -> i32 {
    return x + 1;
}

fn main() -> void {
    val two = @cpp("{0} + 1", 1);
    var m = 41;
    *id(&m) = 9;
    std::println("root {} {} {}", two, m, kind(next));
}
// expect: root 2 9 fn(i32) -> i32
