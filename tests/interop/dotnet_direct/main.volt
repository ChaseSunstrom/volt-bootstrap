use std::io;
// Volt calling ordinary C# (Geo.cs, nothing in it is written for Volt): the use line is all it
// takes, with voltc run main.volt or in a bolt package. .NET starts on first use
use { "Geo.cs" } as geo;

fn main() -> void {
    // a struct of plain fields: a Volt struct, by value, with its methods
    var p = geo::Point::new(3.0, 4.0);
    std::println("norm {} x {}", p.Norm(), p.X);
    p.Scale(2.0);
    val m = geo::Geom::Mid(p, geo::Point::new(0.0, 0.0));
    std::println("scaled {} {} mid {} {}", p.X, p.Y, m.X, m.ToString());

    // classes: constructors, methods, properties, fields, a static property, inheritance
    var c = geo::Circle::new(2.0);
    std::println("{} {} {} r {}", c.Area(), c.Name(), c.Describe(), c.R());
    c.set_R(1.0);
    c.set_Label("round");
    std::println("area {} label {} made {}", c.Area(), c.Label(), geo::Circle::Made());
    val s1 = c.as_IShape();
    val s2 = c.as_Shape();
    std::println("total {} {}", geo::Geom::Total(&s1, &s1), s2.Describe());

    // enums
    std::println("color {} {}", geo::Geom::Next(geo::Color::Green) == geo::Color::Blue, c.Tint() == geo::Color::Green);

    // overloads, strings, arrays, int?
    std::println("{} {} {} {}", geo::Geom::Add(2, 40), geo::Geom::Add(1.0, 2.0), geo::Geom::Upper("quiet"), geo::Geom::Limit());
    val xs: f64[3] = { 1.5, 2.5, 3.0 };
    std::println("sum {}", geo::Geom::Sum(xs[..]));
    var ys: i32[3] = { 1, 2, 3 };
    geo::Geom::DoubleAll(ys[..]);
    std::println("doubled {} {} {}", ys[0], ys[1], ys[2]);
    val sq = geo::Geom::Squares(4);
    std::println("squares {} last {}", sq.len, *sq.at(3));
    val parts: str[3] = { "a", "b", "c" };
    val w = geo::Geom::Words(" x yy  zzz ");
    std::println("{} words {} {}", geo::Geom::Join(parts[..], "-"), w.len, *w.at(2));
    val zs: i32[3] = { 5, 7, 9 };
    std::println("find {} {}", geo::Geom::Find(zs[..], 9) ?? 99, geo::Geom::Find(zs[..], 4) == null);
    std::println("first {} even {}", geo::Geom::First("volt"), geo::Geom::Even(4));
}
// expect: norm 5 x 3
// expect: scaled 6 8 mid 3 (3, 4)
// expect: 12 circle circle of area 12 r 2
// expect: area 3 label round made 1
// expect: total 6 circle of area 3
// expect: color true true
// expect: 42 3.5 QUIET 10
// expect: sum 7
// expect: doubled 2 4 6
// expect: squares 4 last 16
// expect: a-b-c words 3 zzz
// expect: find 2 true
// expect: first 118 even true
