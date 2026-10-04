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
// expect: hello, volt 3 3
