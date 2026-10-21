// Volt types C++ has no type for (a Volt struct, an optional, an enum with payloads, a tuple, a
// closure, f16 and f128), handed to C++ templates per use and back unchanged; and C++ results Volt
// holds as a fn value (a function pointer) and an array reference
use std::io;
use { "cpp_peruse2.hpp" } as cpp;

struct point { x: i32; y: f64; }

enum shape { DOT, LINE: i32, BOX: f64 }

fn next(x: i32) -> i32 {
    return x + 1;
}

fn main() -> void {
    val p: point = { x: 3, y: 2.5 };
    val q = cpp::pu2::echo(p);
    std::println("struct {} {}", q.x, q.y);
    val o: i32? = 7;
    val n: i32? = null;
    std::println("opt {} {}", cpp::pu2::echo(o), cpp::pu2::echo(n));
    match (cpp::pu2::echo(shape::BOX(1.25))) {
        .BOX(v) => { std::println("enum {}", v); },
        default => { std::println("enum ?"); },
    }
    val t: (i32, f64) = (4, 0.5);
    std::println("tuple {}", cpp::pu2::echo(t));
    val k = 2;
    val dbl = |k| (x: i32) -> i32 { return x * k; };
    val inc: fn(i32) -> i32 = next;
    std::println("closure {} {}", cpp::pu2::call(dbl), cpp::pu2::call(inc));
    // one owning what it captured: lent to a per-use fn with & (by value it moves, as into any Volt
    // fn), and @cpp text lends it, so it's called again
    val s = std::string::from("abc");
    val own = |s| (x: i32) -> i32 { return x + @cast<i32>(s.len()); };
    val twice = @cpp<i32, i32>("pu2::call({0})", own) + @cpp<i32, i32>("pu2::call({0})", own);
    std::println("owned {} {} {}", cpp::pu2::call(&own), cpp::pu2::call(&own), twice);
    val f: f128 = 1.0 / 3.0;
    val h: f16 = 1.5;
    std::println("float {} {}", cpp::pu2::echo(f) == f, cpp::pu2::echo(h));
    std::println("count {}", cpp::pu2::count(p, o, t, f, dbl));
    // a try_ form worked out per use, and @cpp's {t0} of a Volt struct
    val e = @cpp<point, point>("pu2::echo<{t0}>({0})", &p);
    std::println("try {} {}", cpp::pu2::try_count(p, t) catch 0, e.y);
    val g = cpp::pu2::pick();
    std::println("fnptr {} {}", g(4), cpp::pu2::echo(g)(9));
    val a = cpp::pu2::nums();
    a[1] = 50;
    std::println("array {} {}", cpp::pu2::nums()[1], a[2]);
    var b: i32[3] = { 7, 8, 9 };
    val c = cpp::pu2::same(&b);
    c[0] = 70;
    std::println("same {}", b[0]);
}
// expect: struct 3 2.5
// expect: opt 7 null
// expect: enum 1.25
// expect: tuple (4, 0.5)
// expect: closure 40 21
// expect: owned 23 23 46
// expect: float true 1.5
// expect: count 5
// expect: try 2 2.5
// expect: fnptr 5 10
// expect: array 50 6
// expect: same 70
