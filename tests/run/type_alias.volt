// `type name = T;` is another name for a type; a generic one takes arguments where it's used
use std::io;

type meters = f64;
<T: type>
type list = std::vec<T>;
type names = list<std::string>;

struct point {
    x: meters;
    y: meters;
}

type pt = point;

attach fn origin(static this: point) -> point {
    return { x: 0.0, y: 0.0 };
}

fn length(a: meters, b: meters) -> meters {
    return a + b;
}

fn main() -> void {
    val d: meters = 1.5;
    var xs: list<i32> = {};
    xs.push(3);
    xs.push(4);
    var ns: names = {};
    ns.push(std::string::from("hi"));
    val p: pt = { x: 1.0, y: 2.0 };
    val o = pt::origin();
    std::println("{} {} {} {} {} {}", length(d, 2.0), xs.len, *xs.at(1), ns.len, p.x + p.y, o.x);
}
// expect: 3.5 2 4 1 3 0
