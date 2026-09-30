use std::io;

<T: type>
fn max(a: T, b: T) -> T {
    if (a > b) { return a; }
    return b;
}

<T: type>
fn type_name(v: T) -> str { return "something"; }
fn type_name<bool>(v: bool) -> str { return "a bool"; }

<T: type, C: i32 = 3>
struct buf {
    items: T[C];
    len: usize;
}

<T: type>
struct holder { value: T; }

<T: type>
struct holder<T&> { value: T*; }

<T: type>
enum maybe {
    SOME: T,
    NONE,
}

<T: type, N: i32>
fn sum(xs: T[N]) -> T {
    var s: T = 0;
    for (x) in xs { s += x; }
    return s;
}

<Args: type...>
fn count(args: Args...) -> i32 {
    return 0;
}

<T: type>
fn first(pair: (T, T)) -> T { return pair.0; }

fn main() -> void {
    std::println("{} {} {}", max(3, 9), max(2.5, 1.0), max<u8>(200, 100));
    std::println("{} {}", type_name(1), type_name(true));
    var b: buf<i32> = { items: { 1, 2, 3 }, len: 3 };
    std::println("{} {}", b.items[2], @sizeof(buf<u8, 10>));
    var n = 5;
    val h1: holder<i32> = { value: 7 };
    val h2: holder<i32&> = { value: null };
    std::println("{} {}", h1.value, h2.value == null);
    val m = maybe::SOME(4);
    val e: maybe<str> = .NONE;
    std::println("{} {}", m, e);
    val arr: i64[4] = { 1, 2, 3, 4 };
    std::println(sum(arr));
    std::println(first((5, 6)));
    std::println(count(1, "a", true));
}
// expect: 9 2.5 200
// expect: something a bool
// expect: 3 24
// expect: 7 true
// expect: SOME(4) NONE
// expect: 10
// expect: 5
// expect: 0
