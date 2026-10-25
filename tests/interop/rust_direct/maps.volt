use std::io;
use std::string;
// Rust's HashMap and BTreeMap as Volt's std::map, HashSet and BTreeSet as std::set (copies each
// way), a Box<T> as the T itself, and a raw pointer as a Volt T*
use { "geom" } as geom;

fn main() -> void {
    var counts = geom::word_counts("a b a c a");
    val a = counts.get(std::string::from("a")) ?? @panic("no a");
    std::println("maps {} {} {}", counts.len, geom::total_counts(&counts), *a);
    var bm: std::map<i32, f64> = {};
    bm.put(1, 1.5);
    bm.put(2, 2.0);
    var sc = geom::scaled(&bm, 2.0);
    std::println("scaled {} {}", *(sc.get(1) ?? @panic("no 1")), *(sc.get(2) ?? @panic("no 2")));
    var s: std::set<i32> = {};
    s.add(1);
    s.add(2);
    s.add(4);
    var ev = geom::evens_of(&s);
    var ws: std::set<std::string> = {};
    ws.add(std::string::from("volt"));
    ws.add(std::string::from("rust"));
    std::println("sets {} {} {}", ev.len(), ev.contains(4), geom::initials(&ws));
    val bp = geom::boxed_point(1.5);
    std::println("box {} {} {}", bp.x, bp.y, geom::unbox(bp));
    var n: i32 = 41;
    val np: i32* = &n;
    geom::bump_ptr(np);
    std::println("ptr {} {}", geom::read_ptr(np), n);
}
// expect: maps 3 5 3
// expect: scaled 3 4
// expect: sets 2 true rv
// expect: box 1.5 3 4.5
// expect: ptr 42 42
