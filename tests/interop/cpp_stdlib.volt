// The C++ standard library from Volt. Its class templates come by the headers' names, held by handle
// under stdcxx with their members worked out per use, and a for loops over any of them; in a
// header's signatures optional, pair, tuple, array, span, string_view and variant read as T?, a
// tuple, T[N], T[..], str and an enum, and a view loops like a container
use std::io;
use cpp { "map", "unordered_map", "set", "deque", "list" } as cs;
use { "stdlib.hpp" } as cpp;

fn main() -> void {
    var m: cs::stdcxx::map<i32, i32> = {};
    m.insert_or_assign(2, 20);
    m.insert_or_assign(1, 10);
    for (kv) in m {
        std::print("{}:{} ", kv.0, kv.1);
    }
    std::println("| {} {}", m.size(), *m.at(2));
    var u: cs::stdcxx::unordered_map<i32, f64> = {};
    u.insert_or_assign(7, 1.5);
    var s: cs::stdcxx::set<i64> = {};
    val big: i64 = 5000000000;
    s.insert(big);
    s.insert(big);
    var d: cs::stdcxx::deque<i32> = {};
    val three: i32 = 3;
    d.push_back(three);
    d.push_front(three + 1);
    var l: cs::stdcxx::list<f64> = {};
    l.push_back(0.25);
    var c = copy d;
    c.push_back(three);
    std::println("{} {} {} {} {} {} {}", *u.at(7), s.size(), s.contains(big), *d.front(), l.size(), d.size(), c.size());

    std::println("{} {} {} {}", cpp::sl::half(8) ?? 0, cpp::sl::half(3) == null, cpp::sl::or_minus(4), cpp::sl::or_minus(null));
    val p = cpp::sl::split(3.75);
    val t = cpp::sl::info(6);
    std::println("{} {} | {} {} {}", p.0, p.1, t.0, t.1, t.2);
    std::println("{} {} {}", cpp::sl::join((2, 0.5)), cpp::sl::pick((false, 1, 9)), cpp::sl::widen(cpp::sl::parse(true)));
    val a = cpp::sl::triple(4);
    val xs: i64[3] = { 1, 2, 39 };
    std::println("{} {} {}", a[2], cpp::sl::sum3(a), cpp::sl::total(xs[..]));
    std::println("{} {}", cpp::sl::word(2), cpp::sl::length("volt"));
    val reals: bool[2] = { false, true };
    for (real) in reals {
        match (cpp::sl::parse(real)) {
            .I32(n) => { std::println("int {}", n); },
            .F64(x) => { std::println("double {}", x); },
        }
    }
    val sq = cpp::sl::squares(5);
    var sum = 0;
    for (x) in sq {
        sum += x;
    }
    std::println("squares {}", sum);
}
