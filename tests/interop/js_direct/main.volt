use std::io;
// Volt calling an ordinary TypeScript module (geom.ts, nothing in it is written for Volt): the use
// line is all it takes, with voltc run main.volt or in a bolt package. The engine starts on first use
use { "geom.ts" } as geom;
use { "util.js" } as util; // plain JavaScript, typed by the util.d.ts beside it

fn main() -> void {
    // a class: its constructor, methods, fields, a static method
    var p = geom::Point::new(3.0, 4.0);
    std::println("norm {} x {}", p.norm(), p.x());
    p.scale(2.0);
    p.set_y(1.5);
    val o = geom::Point::origin();
    std::println("scaled {} {} dist {} {}", p.x(), p.y(), geom::dist(&p, &o), p.toString());
    std::println("{} {}", geom::VERSION, geom::LIMIT);

    // a getter, a default argument, a static field, a subclass as its base
    val sides: f64[3] = { 3.0, 4.0, 5.0 };
    var s = geom::Shape::new("tri", sides[..]);
    s.add(1.0);
    std::println("{} {} {} / {}", s.perimeter(), s.count(), s.describe(), s.describe("the"));
    val sq = geom::Square::new(3.0);
    val base = sq.as_Shape();
    val l = geom::longest(&s, &base);
    std::println("square {} {} longest {} made {}", sq.area(), sq.perimeter(), l.name(), geom::Shape::made());

    // an enum, an enum field
    std::println("color {} {}", geom::nextColor(geom::Color::Green) == geom::Color::Blue, s.color() == geom::Color::Green);

    // numbers, strings, arrays, null
    std::println("{} {} {}", geom::add(40.0), geom::add(1.0, 1.0), geom::upper("quiet"));
    val xs: f64[3] = { 1.5, 2.5, 3.0 };
    std::println("total {}", geom::total(xs[..]));
    var ys: f64[3] = { 1.0, 2.0, 3.0 };
    geom::doubleAll(ys[..]);
    std::println("doubled {} {} {}", ys[0], ys[1], ys[2]);
    val sqs = geom::squares(4.0);
    val w = geom::words(" x yy  zzz ");
    val parts: str[3] = { "a", "b", "c" };
    std::println("squares {} last {} words {} {} {}", sqs.len, *sqs.at(3), w.len, *w.at(2), geom::join(parts[..]));
    val zs: f64[3] = { 5.0, 7.0, 9.0 };
    std::println("find {} {}", geom::find(zs[..], 9.0) ?? 99.0, geom::find(zs[..], 4.0) == null);
    std::println("even {} maybe {} {}", geom::even(4.0), geom::maybe("").is_null(), geom::maybe("x").name());

    // generics, async functions, callbacks and object types
    var bx = geom::Box<f64>::new(2.0);
    bx.set(bx.get() + 1.0);
    std::println("first {} pair {} {} box {}", geom::first<f64>(xs[..]), geom::pair<f64, bool>(1.0, true), geom::pair<str, f64>("x", 2.5), bx.get());
    std::println("async {} {}", geom::later(21.0), geom::greetLater("x"));
    val n = geom::each(3.0, || (i: f64) -> void { std::print("[{}]", i); });
    std::println("apply {} each {}", geom::apply(|| (x: f64) -> f64 { return x * 3.0; }, 5.0), n);
    geom::keep(|| (s: str) -> std::string { return std::fmt::format("<{}>", s); });
    std::println("kept {} {}", geom::callKept("a"), geom::callKept("b"));
    val sz: geom::Size = { w: 2.0, h: 3.0, tag: null };
    val big = geom::grow(copy sz, 2.0);
    val r: geom::Range = { lo: 1.5, hi: 4.0 };
    std::println("area {} {} grown {} {} {} span {}", geom::area(copy sz), geom::area({ w: 1.0, h: 1.0, tag: 5.0 }), big.w, big.h, big.tag == null, geom::span(r));
    val named: geom::Size = { w: 1.0, h: 2.0, tag: null, label: std::string::from("s") };
    val sq = geom::squareSizes(3.0);
    std::println("label {} {} squares {} total {}", geom::labelOf(geom::grow(named, 1.0)), geom::labelOf(sz), sq.len, geom::totalArea(sq.items()));
    val bp = geom::Box<geom::Point>::new(geom::Point::new(1.0, 2.0));
    val gp = bp.get();
    geom::tick();
    std::println("more {} {} {} {} {}", geom::first<geom::Size>(sq.items()).w, gp.x(), bx.settled(), geom::soon(1.0), geom::ticked());

    // JavaScript with a .d.ts
    var c = util::Counter::new(1.0);
    c.tick();
    std::println("{} {} {}", util::greet("volt"), c.tick(), c.n());
}
// expect: norm 5 x 3
// expect: scaled 6 1.5 dist 6.18465843842649 (6, 1.5)
// expect: 1.2 10
// expect: 13 4 a tri with 4 sides / the tri with 4 sides
// expect: square 9 12 longest tri made 2
// expect: color true true
// expect: 42 2 QUIET
// expect: total 7
// expect: doubled 2 4 6
// expect: squares 4 last 16 words 3 zzz a-b-c
// expect: find 2 true
// expect: even true maybe true x
// expect: first 1.5 pair 1/true x/2.5 box 3
// expect: async 42 later x
// expect: [0][1][2]apply 15 each 3
// expect: kept <a> <b>
// expect: area 6 6 grown 4 6 true span 2.5
// expect: label s! none squares 3 total 14
// expect: more 1 1 3 2 1
// expect: hello, volt 3 3
