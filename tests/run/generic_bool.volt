// a bool generic value parameter, passed on: a method of sg<T, B> takes the struct as this, and a
// generic fn passes B to another
use std::io;

<T: type, B: bool>
struct sg {
    v: T;
}

<T: type, B: bool>
attach fn get(this: sg<T, B>&) -> T {
    return this.v;
}

<B: bool>
fn wrap(x: i32) -> i32 {
    val s: sg<i32, B> = { v: x };
    return s.get() + 1;
}

fn main() -> void {
    val a: sg<i32, true> = { v: 4 };
    val b: sg<i32, false> = { v: 6 };
    std::println("{} {} {} {}", a.get(), b.get(), wrap<true>(5), wrap<false>(7));
}
// expect: 4 6 6 8
