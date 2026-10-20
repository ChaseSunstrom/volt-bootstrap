// @typeof(x) as a type: a let's type, a generic argument, and a builtin's argument, each seeing the
// locals where it's written
use std::io;

fn main() -> void {
    val a: i32 = 5;
    val b: @typeof(a) = 7;
    var xs: std::vec<@typeof(a)> = {};
    xs.push(b);
    std::println("{} {} {}", xs.len, *xs.at(0), @typeinfo(@typeof(b)).short_name);
}
// expect: 1 7 i32
