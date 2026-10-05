// operators on structs: attach operator <op>(this: T, other: U) -> R is a method the operator calls
// with its left operand as this. < gives > <= >=, == is eq (and gives !=), [] returning T& is a
// place, and a += b is a = a + b with the place evaluated once
use std::io;

struct vec2 {
    x: i32;
    y: i32;
}

attach operator +(this: vec2, o: vec2) -> vec2 {
    return { x: this.x + o.x, y: this.y + o.y };
}

attach operator -(this: vec2, o: vec2) -> vec2 {
    return { x: this.x - o.x, y: this.y - o.y };
}

attach operator -(this: vec2) -> vec2 {
    return { x: -this.x, y: -this.y };
}

// overloads pick by the right operand: a scale, or a dot product
attach operator *(this: vec2, k: i32) -> vec2 {
    return { x: this.x * k, y: this.y * k };
}

attach operator *(this: vec2, o: vec2) -> i32 {
    return this.x * o.x + this.y * o.y;
}

attach operator /(this: vec2, k: i32) -> vec2 {
    return { x: this.x / k, y: this.y / k };
}

attach operator %(this: vec2, k: i32) -> vec2 {
    return { x: this.x % k, y: this.y % k };
}

attach operator ==(this: vec2&, o: vec2&) -> bool {
    return this.x == o.x && this.y == o.y;
}

struct mask {
    bits: u8;
}

attach operator &(this: mask, o: mask) -> mask {
    return { bits: this.bits & o.bits };
}

attach operator |(this: mask, o: mask) -> mask {
    return { bits: this.bits | o.bits };
}

attach operator ^(this: mask, o: mask) -> mask {
    return { bits: this.bits ^ o.bits };
}

attach operator ~(this: mask) -> mask {
    return { bits: ~this.bits };
}

attach operator <<(this: mask, n: u8) -> mask {
    return { bits: this.bits << n };
}

attach operator >>(this: mask, n: u8) -> mask {
    return { bits: this.bits >> n };
}

// by reference: both operands lend their address, and a temporary lives until the call is done
struct money {
    cents: i64;
}

attach operator <(this: money&, o: money&) -> bool {
    return this.cents < o.cents;
}

attach operator +(this: money&, o: money&) -> money {
    return { cents: this.cents + o.cents };
}

fn traced(label: str, cents: i64) -> money {
    std::print("{label} ");
    return { cents };
}

// [] can return a value too
struct rgb {
    r: u8;
    g: u8;
    b: u8;
}

attach operator [](this: rgb, i: usize) -> u8 {
    if (i == 0) {
        return this.r;
    }
    if (i == 1) {
        return this.g;
    }
    return this.b;
}

// `attach operator -> T` is still an attach block, of a trait named operator
trait operator {
    fn size(this) -> i32;
}

attach operator -> rgb {
    fn size(this) -> i32 {
        return 3;
    }
}

// an enum, and an operator reached through a reference (this: T&)
enum dir {
    N,
    E,
    S,
    W,
}

attach operator -(this: dir) -> dir {
    match (this) {
        .N => { return dir::S; },
        .S => { return dir::N; },
        .E => { return dir::W; },
        default => { return dir::E; },
    }
}

attach fn moved(this: vec2&, by: vec2) -> vec2 {
    return this + by;
}

// overloads taking the right operand by value and by reference
struct span2 {
    w: i32;
}

attach operator *(this: span2, k: i32) -> span2 {
    return { w: this.w * k };
}

attach operator *(this: span2, o: span2&) -> span2 {
    return { w: this.w * o.w };
}

// [] returning a reference is a place: read it, assign to it, += it
struct grid {
    cells: i32[6];
    width: i32;
}

attach operator [](this: grid&, at: vec2) -> i32& {
    return &this.cells[@cast<usize>(at.y * this.width + at.x)];
}

fn pick(at: vec2) -> vec2 {
    std::print("pick ");
    return at;
}

// an owned value: the old one is deleted when += stores the new
struct words {
    s: std::string;
}

attach operator +(this: words&, o: words&) -> words {
    var s = copy this.s;
    s.append(" ");
    s.append(o.s.as_str());
    return { s };
}

// by value: x += y moves x into the operator, even in a loop, and takes the result back
struct chain {
    s: std::string;
}

attach operator +(this: chain, o: chain&) -> chain {
    var s = copy this.s;
    s.append(o.s.as_str());
    return { s };
}

<T: type>
struct pair {
    first: T;
    second: T;
}

<T: type>
attach operator +(this: pair<T>, o: pair<T>) -> pair<T> {
    return { first: this.first + o.first, second: this.second + o.second };
}

fn main() -> void {
    val a: vec2 = { x: 1, y: 2 };
    val b: vec2 = { x: 3, y: 5 };
    val s = a + b;
    val d = b - a;
    val n = -a;
    std::println("{} {} {} {} {} {}", s.x, s.y, d.x, d.y, n.x, n.y);
    val k = a + b * 2;
    val q = b / 2;
    val r = b % 2;
    std::println("{} {} {} {} {}", k.x, k.y, a * b, q.y, r.x);
    std::println("{} {} {}", a == b, a + b == s, a != b);

    val m: mask = { bits: 12 };
    val o: mask = { bits: 10 };
    std::println("{} {} {} {} {} {}", (m & o).bits, (m | o).bits, (m ^ o).bits, (~m).bits, (m << 1).bits, (m >> 2).bits);

    // left to right, even when the operator runs with them swapped
    std::println("{}", traced("a", 1) < traced("b", 2));
    std::println("{}", traced("c", 1) > traced("d", 2));
    std::println("{}", traced("e", 3) <= traced("f", 3));
    std::println("{}", traced("g", 5) >= traced("h", 4));
    val total = traced("i", 1) + traced("j", 2) + traced("k", 3);
    std::println("{}", total.cents);

    var g: grid = { cells: { 0; 6 }, width: 3 };
    g[{ x: 1, y: 1 }] = 7;
    g[{ x: 1, y: 1 }] += 3;
    g[{ x: 2, y: 0 }] = g[{ x: 1, y: 1 }] * 2;
    g[pick({ x: 0, y: 0 })] += 5;
    std::println("{} {} {} {}", g.cells[4], g.cells[2], g[{ x: 2, y: 0 }], g.cells[0]);

    var p: vec2 = { x: 0, y: 0 };
    p += a;
    p += b;
    p -= { x: 1, y: 1 };
    p *= 2;
    std::println("{} {}", p.x, p.y);

    var w: words = { s: std::string::from("hello") };
    val v: words = { s: std::string::from("world") };
    w += v;
    w = w + v;
    std::println("{}", w.s.as_str());
    // the temporary v + v is lent by reference and deleted after the call
    val z = v + (v + v);
    std::println("{}", z.s.as_str());
    var c: chain = { s: std::string::from("a") };
    val link: chain = { s: std::string::from("b") };
    for (i) in 0..3 {
        c += link;
    }
    std::println("{}", c.s.as_str());

    val col: rgb = { r: 10, g: 20, b: 30 };
    val turned = -dir::E;
    val sp: span2 = { w: 3 };
    var k = 4;
    k += 1;
    std::println("{} {} {} {} {} {}", col[1], turned == dir::W, a.moved(b).y, (sp * k).w, (sp * sp).w, col.size());

    val pi: pair<i32> = { first: 1, second: 2 };
    val pf: pair<f64> = { first: 0.25, second: 1.25 };
    val si = pi + pi;
    val sf = pf + pf;
    std::println("{} {} {} {}", si.first, si.second, sf.first, sf.second);
}
// flags: --leak-check
// expect: 4 7 2 3 -1 -2
// expect: 7 12 13 2 1
// expect: false true true
// expect: 8 14 6 243 24 3
// expect: a b true
// expect: c d false
// expect: e f true
// expect: g h true
// expect: i j k 6
// expect: pick 10 20 20 5
// expect: 6 12
// expect: hello world world
// expect: world world world
// expect: abbb
// expect: 20 true 7 15 9 3
// expect: 2 4 0.5 2.5
