// @derive(eq, hash, fmt, json): methods written in std (std/derive.volt) over the type's fields; ==
// and != call eq, and a derived type is a map key
use std::io;

enum color {
    RED,
    GREEN,
}

@attributes([@derive(eq, hash, fmt, json)])
struct point {
    x: i32;
    y: i32;
}

@attributes([@derive(eq, hash, json)])
struct pin {
    name: std::string;
    at: point;
    tags: std::vec<str>;
    note: str?;
}

@attributes([@derive(eq, hash, json)])
enum mode {
    ON,
    OFF,
}

// a generic struct derives for each instance
@attributes([@derive(eq)])
<T: type>
struct pair {
    a: T;
    b: T;
}

fn make_point(x: i32) -> point {
    return { x: x, y: 2 };
}

fn main() -> void {
    val a: point = { x: 1, y: 2 };
    val b: point = { x: 1, y: 2 };
    val c: point = { x: 2, y: 1 };
    std::println("{} {} {} {}", a == b, a != c, a.eq(&c), a.hash() == b.hash());
    std::println("{}", a.to_string());
    var p: pin = { name: std::string::from("home"), at: a, tags: {}, note: null };
    p.tags.push("x") catch @panic("oom");
    val q = copy p;
    std::println("{} {}", p == q, p.to_json().text());
    var seen: std::map<point, str> = {};
    seen.put(a, "a");
    std::println("{} {}", *seen.get(b), seen.get(c) == null);
    std::println("{} {}", mode::ON == mode::ON, mode::ON.hash() != mode::OFF.hash());
    val s = std::string::from("s");
    std::println("{} {}", s == std::string::from("s"), std::string::from("t") != s);
    val pa: pair<i32> = { a: 1, b: 2 };
    val pb: pair<i32> = { a: 1, b: 2 };
    std::println("{} {}", pa == pb, p.hash() == q.hash());
    // a temporary on either side, and a field of one
    val pts: point[] = { a, c };
    std::println("{} {} {}", make_point(1) == a, pts[0] == make_point(1), make_point(2).x == 2);
    std::println("{}", mode::OFF.to_json().text());
}
// expect: true true false true
// expect: point { x: 1, y: 2 }
// expect: true {"name":"home","at":{"x":1,"y":2},"tags":["x"],"note":null}
// expect: a true
// expect: true true
// expect: true true
// expect: true true
// expect: true true true
// expect: "OFF"
