use std::io;
// A generic closure: |caps| <T: type>(x: T) -> T { }. Its captures are taken once; each call infers T
// from the arguments and gets a body for it. A template or a fn(...) value gets one too.

<F: type>
fn twice(f: F) -> i32 {
    return f(1) + f(2);
}

<U: type>
fn pair_with(u: U) -> void {
    val p = |u| <T: type>(t: T) -> void { std::println("{} {}", u, t); };
    p(1);
    p("x");
}

fn main() -> void {
    val base = 10;
    var calls = 0;
    val show = |base, calls&| <T: type>(x: T) -> T {
        calls += 1;
        std::println("{} {}", base, x);
        return x;
    };
    val a = show(5);
    val b = show("hi");
    val c = show(2.5);
    std::println("{} {} {} {}", a, b, c, calls);

    val id = |calls&| <T: type>(x: T) -> T {
        calls += 1;
        return x;
    };
    std::println("{} {}", twice(id), calls);
    val f: fn(i64) -> i64 = id;
    std::println("{} {}", f(40) + 2, calls);

    // a parameter that doesn't name T takes its argument as its own type
    val scaled = || <T: type>(x: T, by: u8) -> T { return x * @cast<T>(by); };
    std::println("{} {}", scaled(3, 4), scaled(1.5, 2));
    pair_with(true);
    pair_with(3.5);
}
// expect: 10 5
// expect: 10 hi
// expect: 10 2.5
// expect: 5 hi 2.5 3
// expect: 3 5
// expect: 42 6
// expect: 12 3
// expect: true 1
// expect: true x
// expect: 3.5 1
// expect: 3.5 x
