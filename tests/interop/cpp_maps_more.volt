// cpp_maps_more.hpp: a Volt std::map for a map with another order (copied into C++'s, which keeps
// its own order), a mutable map& (C++'s changes go back), enum keys and values, struct values
use std::io;
use { "cpp_maps_more.hpp" } as cpp;

fn main() -> void {
    var m: std::map<i32, i32> = {};
    m.put(1, 1);
    m.put(5, 5);
    m.put(3, 3);
    std::println("first_desc {}", cpp::mm::first_desc(&m));
    var w: std::map<std::string, i32> = {};
    w.put(std::string::from("ccc"), 1);
    w.put(std::string::from("a"), 2);
    std::println("shortest {}", cpp::mm::shortest(&w));
    val n = cpp::mm::bump(&w);
    std::println("bump {} {} {} {}", n, *(w.get(std::string::from("a")) ?? return), *(w.get(std::string::from("ccc")) ?? return), *(w.get(std::string::from("new")) ?? return));
    m.put(4, 4);
    cpp::mm::drop_odd(&m);
    std::println("drop_odd {} {}", m.contains(1), m.len);
    var c: std::map<cpp::mm::Color, i32> = {};
    c.put(cpp::mm::Color::RED, 4);
    std::println("reds {}", cpp::mm::reds(&c));
    var p: std::map<i32, cpp::mm::Color> = {};
    cpp::mm::paint(&p);
    std::println("paint {}", *(p.get(9) ?? return) == cpp::mm::Color::BLUE);
    var q: std::map<i32, cpp::mm::pt> = {};
    q.put(1, { x: 2, y: 0 });
    q.put(2, { x: 5, y: 0 });
    std::println("xsum {}", cpp::mm::xsum(&q));
}
