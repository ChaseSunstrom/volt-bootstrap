use std::io;
val LIMIT: i32 = 3 * 4;
var counter: i32 = 0;

namespace geo {
    struct vec2 { x: f64; y: f64; }
    fn len2(v: vec2) -> f64 { return v.x * v.x + v.y * v.y; }
    namespace inner {
        fn twice(n: i32) -> i32 { return n * 2; }
    }
}

fn bump(p: i32&) -> void {
    *p += 1;
}

fn main() -> void {
    counter += LIMIT;
    bump(&counter);
    std::println(counter);
    val v: geo::vec2 = { x: 3.0, y: 4.0 };
    std::println(geo::len2(v));
    std::println(geo::inner::twice(21));
    var shifts: u32 = 1 << 4;
    shifts >>= 2;
    std::println("{} {} {}", shifts, 7 / 2, -7 % 3);
    val big: i64 = 1 << 40;
    std::println(big);
    val c: u8 = 'A';
    std::println("{} {}", c, c as i32 + 1);
    val s = "hello";
    std::println("{} {} {}", s.len, s[1], s == "hello");
    var maybe: i32? = null;
    std::println(maybe);
    maybe = 5;
    std::println("{} {}", maybe, maybe == null);
}
// expect: 13
// expect: 25
// expect: 42
// expect: 4 3 -1
// expect: 1099511627776
// expect: 65 66
// expect: 5 101 true
// expect: null
// expect: 5 false
