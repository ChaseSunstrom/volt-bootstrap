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
    var pl = geom::places();
    val home = pl.get(std::string::from("home")) ?? @panic("no home");
    var cs: std::map<i32, geom::Color> = {};
    cs.put(2, geom::Color::Green);
    cs.put(1, geom::Color::Red);
    std::println("places {} {} {} {}", pl.len, home.x, home.y, geom::paint(&cs));
    var sc = geom::suit_counts();
    val hearts = sc.get(geom::Suit::Hearts) ?? @panic("no hearts");
    val h = *hearts;
    sc.put(geom::Suit::Spades, 5);
    var cl = geom::cells();
    val added = cl.add({ r: 5, c: 6 });
    std::println("keys {} {} {} {} {} {}", sc.len, h, geom::suit_total(&sc), cl.len(), added, geom::cell_sum(&cl));
    std::println("cow {} {}", geom::cow_upper("hi there"), geom::keep("as is"));
    var pv: std::vec<i32> = {};
    pv.push(7) catch @panic("out of memory");
    geom::push_evens(&pv, 3);
    var wm: std::map<std::string, i32> = {};
    geom::add_word(&wm, "x");
    geom::add_word(&wm, "x");
    geom::add_word(&wm, "y");
    val xc = wm.get(std::string::from("x")) ?? @panic("no x");
    val xn = *xc;
    var ss: std::set<geom::Suit> = {};
    val first = geom::add_suit(&ss, geom::Suit::Hearts);
    val again = geom::add_suit(&ss, geom::Suit::Hearts);
    val dc = geom::doubled_cow(pv.items());
    std::println("written {} {} {} {} {} {} {} {}", pv.len, pv[3], wm.len, xn, ss.len(), first, again, dc[3]);
    val spt = geom::shared_point(1.5);
    val ns: i32[2] = { 1, 2 };
    val an = geom::arc_nums();
    std::println("shared {} {} {} {} {}", spt.x, geom::rc_len(ns[..]), geom::arc_name("abcd"), an.len, an[2]);
    std::println("vec {}", geom::vec_total(pv.items()));
}
// expect: maps 3 5 3
// expect: scaled 3 4
// expect: sets 2 true rv
// expect: box 1.5 3 4.5
// expect: ptr 42 42
// expect: places 2 1 2 1:Red,2:Green
// expect: keys 2 3 35 3 true 102
// expect: cow HI THERE as is
// expect: written 4 4 2 2 1 true false 8
// expect: shared 1.5 2 4 3 6
// expect: vec 13
