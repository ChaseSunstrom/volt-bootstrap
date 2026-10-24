use std::io;
// tuples, arrays, 128-bit integers, traits with associated types, generic traits, supertraits
// and associated consts, and a fn a macro makes
use { "geom" } as geom;

// any Source<i32>: Rust's own (Countdown, a Box<dyn Source<Item = i32>>)
<S: geom::Source<i32>>
fn total(s: S&) -> i32 {
    var t = 0;
    while (true) {
        val v = s.next_item() ?? break;
        t += v;
    }
    return t;
}

fn main() -> void {
    val (a, b) = geom::swap_pair((3, 1.5));
    val xs: i64[3] = { 4, -2, 9 };
    val (lo, hi) = geom::min_max(xs[..]);
    val (label, next) = geom::label_of(7);
    std::println("tuple {} {} {} {} {} {}", a, b, lo, hi, label, next);
    val arr: i32[3] = { 1, 2, 3 };
    val r = geom::reversed(arr[..]);
    std::println("array {} {} {}", *r.at(0), *r.at(1), *r.at(2));
    val big: u128 = 18446744073709551615;
    std::println("u128 {} {}", geom::big_mul(big, 2) == big * 2, geom::negate(-5) == 5);

    var c = geom::Countdown::new(3);
    val first = c.next_item() ?? 0;
    var d = geom::countdown(4);
    std::println("source {} {} {}", first, total(&c), total(&d));
    var e = geom::Countdown::new(5);
    val half: f64 = e.convert();
    val text: std::string = e.convert();
    std::println("convert {} {}", half, text);
    std::println("super {} {}", e.greet(), e.name());
    std::println("const {} {}", geom::Countdown::CAP(), e.used());
    std::println("macro {}", geom::made_by_macro());
    // a generic trait taking its parameter's values (Store<i32>), a generic supertrait (Labeled:
    // Convert<i32>) and a std one with methods (Shown: Display)
    var b = geom::Bin::new();
    b.put(5);
    b.put(2);
    std::println("store {} {}", b.label_n(), b.shown());
    std::println("taken {} {}", b.take(), b.convert());
    var w = geom::Words::new("ab");
    std::println("words {}", w.take());
}
// expect: tuple 1.5 3 -2 9 #7 8
// expect: array 3 2 1
// expect: u128 true true
// expect: source 3 3 10
// expect: convert 2.5 n=5
// expect: super hello from countdown countdown
// expect: const 10 5
// expect: macro 7
// expect: store #700 <bin(7)>
// expect: taken 7 0
// expect: words ab
