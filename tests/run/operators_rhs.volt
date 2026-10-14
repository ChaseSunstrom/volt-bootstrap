// right-hand operators: this as the second parameter attaches a binary operator to the right
// operand's type, so 2.0 * v calls vec2's. a op b takes a's operator (this first) when one fits,
// else b's (this second); the operands are evaluated left to right either way
use std::io;

struct vec2 {
    x: f64;
    y: f64;
}

attach operator *(this: vec2, k: f64) -> vec2 {
    return { x: this.x * k, y: this.y * k };
}

attach operator *(k: f64, this: vec2) -> vec2 {
    return { x: k * this.x + 100.0, y: k * this.y + 100.0 };
}

// only the right-hand version: 3 * d works, d * 3 doesn't
struct dir {
    dx: i32;
    dy: i32;
}

attach operator *(k: i32, this: dir) -> dir {
    return { dx: k * this.dx, dy: k * this.dy };
}

// right-hand overloads pick by the left operand, as call overloads do
attach operator *(s: str, this: dir) -> str {
    return s;
}

// 3 < m, and m > 3 (that's 3 < m), by reference: a temporary lives until the call is done
struct money {
    cents: i64;
}

attach operator <(n: i64, this: money&) -> bool {
    return n < this.cents;
}

fn cash(cents: i64) -> money {
    return { cents };
}

// a left-hand operator of one type and a right-hand one of another: the left one wins
struct meters {
    m: i32;
}

struct scale {
    k: i32;
}

attach operator *(this: meters, s: scale) -> str {
    return "meters'";
}

attach operator *(m: meters, this: scale) -> str {
    return "scale's";
}

// meters' * doesn't take a ratio, so ratio's right-hand one is called
struct ratio {
    r: i32;
}

attach operator *(m: meters, this: ratio) -> i32 {
    return m.m * this.r;
}

// a right-hand wrapping operator
struct fix {
    raw: u8;
}

attach operator +%(k: u8, this: fix) -> fix {
    return { raw: k +% this.raw };
}

// an enum as the right operand
enum level {
    LOW,
    HIGH,
}

attach operator *(k: i32, this: level) -> i32 {
    match (this) {
        .LOW => { return k; },
        .HIGH => { return k * 10; },
    }
}

// a left operand the right one changes: it's read first, as the operands go left to right
fn bump(n: f64&) -> vec2 {
    *n += 1.0;
    return { x: 1.0, y: 1.0 };
}

// an owned result, and an owned operand lent by reference
struct words {
    s: std::string;
}

attach operator +(p: str, this: words&) -> words {
    var s = std::string::from(p);
    s.append(this.s.as_str());
    return { s };
}

fn words_of(s: str) -> words {
    return { s: std::string::from(s) };
}

fn traced(label: str, k: f64) -> f64 {
    std::print("{label} ");
    return k;
}

fn traced_v(label: str, v: vec2) -> vec2 {
    std::print("{label} ");
    return v;
}

fn main() -> void {
    val v: vec2 = { x: 1.0, y: 2.0 };
    val a = v * 2.0;
    std::println("{} {}", a.x, a.y);
    val b = 2.0 * v;
    std::println("{} {}", b.x, b.y);
    // a literal 2 fits the f64 parameter, as in a call
    val c = 2 * v;
    std::println("{} {}", c.x, c.y);
    val d: dir = { dx: 1, dy: -2 };
    val e = 3 * d;
    std::println("{} {}", e.dx, e.dy);
    val m: money = { cents: 5 };
    std::println("{} {}", 3 < m, 7 < m);
    std::println("{} {}", m > 3, m > 7);
    std::println("{}", 4 < cash(9));
    val f = traced("left", 3.0) * traced_v("right", v);
    std::println("{} {}", f.x, f.y);
    val g = traced("left", 3.0) * v;
    std::println("{}", g.x);
    val len: meters = { m: 2 };
    val k: scale = { k: 3 };
    std::println("{}", len * k);
    val w: words = { s: std::string::from("world") };
    val hi = "hello " + w;
    std::println("{}", hi.s);
    // a temporary this lives until the call is done, then it's deleted
    val bye = "bye " + words_of("you");
    std::println("{}", bye.s);
    val r: ratio = { r: 5 };
    std::println("{}", len * r);
    val fx: fix = { raw: 100 };
    std::println("{}", (200 +% fx).raw);
    std::println("{} {}", 3 * level::LOW, 3 * level::HIGH);
    std::println("{}", "picked by str" * d);
    // a >= b is !(a < b): b's right-hand < serves 3 >= m; a <= b is !(b < a): m <= 3 is !(3 < m)
    std::println("{} {}", 3 >= m, 7 >= m);
    std::println("{} {}", m <= 3, m <= 7);
    var n = 2.0;
    val h = n * bump(&n);
    std::println("{} {}", h.x, n);
    // a right-hand operator is no method: @typeinfo(T).methods leaves it out
    comptime for (meth) in @typeinfo(vec2).methods {
        std::println("method {}", meth.name);
    }
}
// expect: 2 4
// expect: 102 104
// expect: 102 104
// expect: 3 -6
// expect: true false
// expect: true false
// expect: true
// expect: left right 103 106
// expect: left 103
// expect: meters'
// expect: hello world
// expect: bye you
// expect: 10
// expect: 44
// expect: 3 30
// expect: picked by str
// expect: false true
// expect: false true
// expect: 102 3
// expect: method operator*
// flags: --leak-check
