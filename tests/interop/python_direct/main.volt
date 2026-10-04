use std::io;
// Volt calling an ordinary Python module (geom.py, nothing in it is written for Volt): the use line
// is all it takes, with voltc run main.volt or in a bolt package. Python starts on first use
use { "geom.py" } as geom;

fn main() -> void {
    // a dataclass: its constructor, methods, attributes, a static and a class method
    var p = geom::Point::new(3.0, 4.0);
    std::println("norm {} x {}", p.norm(), p.x());
    p.scale(2.0);
    p.set_y(1.5);
    val o = geom::Point::origin();
    std::println("scaled {} {} dist {}", p.x(), p.y(), geom::dist(&p, &o));
    val q = geom::Point::parse("1,2");
    std::println("parsed {} {} {} {} {}", q.x(), q.y(), geom::VERSION, geom::LIMIT, geom::RATIO);

    // a class: a property, a default argument, a subclass as its base
    val sides: f64[3] = { 3.0, 4.0, 5.0 };
    var s = geom::Shape::new("tri", sides[..]);
    s.add(1.0);
    std::println("{} {} {} / {}", s.perimeter(), s.count(), s.describe(), s.describe("the"));
    val sq = geom::Square::new(3.0);
    val base = sq.as_Shape();
    val l = geom::longest(&s, &base);
    std::println("square {} {} longest {}", sq.area(), sq.perimeter(), l.name());

    // an enum, an enum attribute
    std::println("color {} {}", geom::next_color(geom::Color::GREEN) == geom::Color::BLUE, s.color() == geom::Color::GREEN);

    // numbers, strings, lists, bytes, optionals, a keyword-only argument
    std::println("{} {} {}", geom::add(40), geom::add(1, 1), geom::upper("quiet"));
    val xs: f64[3] = { 1.5, 2.5, 3.0 };
    std::println("total {}", geom::total(xs[..]));
    var ys: i64[3] = { 1, 2, 3 };
    geom::double_all(ys[..]);
    std::println("doubled {} {} {}", ys[0], ys[1], ys[2]);
    val sqs = geom::squares(4);
    val w = geom::words(" x yy  zzz ");
    val parts: str[3] = { "a", "b", "c" };
    std::println("squares {} last {} words {} {} {}", sqs.len, *sqs.at(3), w.len, *w.at(2), geom::join(parts[..]));
    val zs: i64[3] = { 5, 7, 9 };
    std::println("find {} {}", geom::find(zs[..], 9) ?? 99, geom::find(zs[..], 4) == null);
    std::println("{} / {}", geom::greet("volt"), geom::greet("volt", true));
    val data: u8[3] = { 1, 2, 3 };
    std::println("checksum {} maybe {} {}", geom::checksum(data[..]), geom::maybe("").is_null(), geom::maybe("x").name());
}
// expect: norm 5 x 3
// expect: scaled 6 1.5 dist 6.18465843842649
// expect: parsed 1 2 1.2 10 0.5
// expect: 13 4 a tri with 4 sides / the tri with 4 sides
// expect: square 9 12 longest tri
// expect: color true true
// expect: 42 2 QUIET
// expect: total 7
// expect: doubled 2 4 6
// expect: squares 4 last 16 words 3 zzz a-b-c
// expect: find 2 true
// expect: hello, volt / HELLO, VOLT
// expect: checksum 6 maybe true x
