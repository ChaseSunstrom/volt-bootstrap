// a generic trait fn through a trait nothing attaches: explicit generic arguments bind, an argument
// whose parameter type is a generic checks as given, and a result naming a generic is never (no value
// of the trait exists, so the call never runs)
use std::io;

trait store {
    <T: type> fn put(this, x: T) -> T;
    <T: type> fn make(this) -> T;
    fn count(this) -> i32;
}

fn use_it(s: store&) -> i32 {
    val a = s.put<i32>(3);
    val b: f64 = s.put(2.5);
    val c: i32 = s.make<i32>();
    return a + c + @cast<i32>(b) + s.count();
}

fn main() -> void {
    val none: store[] = {};
    std::println("{}", none.len);
    if (none.len > 0) {
        std::println("{}", use_it(&none[0]));
    }
}
// expect: 0
