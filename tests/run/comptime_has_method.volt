// @has_method(T, "name", A...): does T have a method of that name whose first arguments are As
use std::io;

struct a { n: i32; }
struct b { n: i32; }
struct w { n: i32; }

attach fn name(this: w&, x: a&) -> i32 { return 1; }
attach fn size(this: w&, x: i32, y: b) -> i32 { return 2; }

<T: type>
attach fn len(this: T&) -> i32 { return 3; }

fn main() -> void {
    std::println("{} {} {}", @has_method(w, "name", a&), @has_method(w, "name", b&), @has_method(w, "name"));
    std::println("{} {} {}", @has_method(w, "size", i32, b), @has_method(w, "size", i32, b, i32), @has_method(w, "size", i64));
    std::println("{} {} {}", @has_method(w, "len"), @has_method(a, "len"), @has_method(w, "nope"));
}
// expect: true false true
// expect: true false false
// expect: true true false
