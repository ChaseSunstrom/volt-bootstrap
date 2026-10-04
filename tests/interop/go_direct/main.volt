use std::io;
// Volt calling ordinary Go (geom.go, nothing in it is written for Volt): the use line is all it
// takes, with voltc run main.volt or in a bolt package
use { "geom.go" } as geom;
use { "shapes" } as sh;         // a directory with a go.mod: its module's package
use { "tool/tool.go" } as tool; // a main package

fn run() -> geom::go_error!void {
    // plain structs by value, and their methods
    val a: geom::Point = { X: 0.0, Y: 0.0 };
    var b: geom::Point = { X: 3.0, Y: 4.0 };
    std::println("dist {} norm {}", geom::Dist(a, b), b.Norm());
    b.Scale(2.0);
    val m = geom::Mid(a, b);
    std::println("scaled {} {} mid {} {}", b.X, b.Y, m.X, m.Y);
    std::println("{} {} {}", geom::Version, geom::Limit, geom::Ratio);

    // an enum, its method, and a struct holding one (changed through a *Pixel)
    val c = geom::Next(geom::Color::Blue);
    std::println("color {} {}", c.Name(), geom::Color::Green.Name());
    var px: geom::Pixel = { At: { X: 1.0, Y: 2.0 }, Color: geom::Color::Red };
    geom::Brighten(&px);
    std::println("pixel {} {}", px.At.Y, px.Color.Name());

    // text and slices
    val parts: str[3] = { "a", "b", "c" };
    std::println("{} {}", geom::Upper("quiet"), geom::Join(parts[..], "-"));
    val xs: f64[3] = { 1.5, 2.5, 3.0 };
    std::println("sum {}", geom::Sum(xs[..]));
    var ys: isize[3] = { 1, 2, 3 };
    geom::Double(ys[..]);
    std::println("doubled {} {} {}", ys[0], ys[1], ys[2]);
    val sq = geom::Squares(4);
    std::println("squares {} last {}", sq.len, *sq.at(3));
    val w = geom::Words(" a bb  ccc ");
    std::println("words {} {}", w.len, *w.at(2));

    // (T, bool) is T?, (T, error) and error are go_error results
    val zs: isize[3] = { 5, 7, 9 };
    std::println("find {} {}", geom::Find(zs[..], 9) ?? 99, geom::Find(zs[..], 4) == null);
    std::println("parse {}", try geom::Parse(" 42 "));
    val bad = geom::Parse("x");
    if (bad.err) {
        std::println("bad {}", bad.err);
    }
    try geom::Check(true);

    // any other struct: a handle, and Go keeps the value while Volt holds it
    val sides: f64[3] = { 3.0, 4.0, 5.0 };
    var s = geom::NewShape("tri", sides[..]);
    var q = geom::NewShape("quad", sides[0..2]);
    q.Add(10.0);
    std::println("perimeter {} {} {}", s.Perimeter(), q.Perimeter(), s.Describe());
    std::println("side {}", try s.Side(1));
    val missing = s.Side(9);
    if (missing.err) {
        std::println("missing {}", missing.err);
    }
    var l = geom::Longest(&s, &q);
    l.Add(1.0);
    std::println("longest {} {}", l.Describe(), q.Perimeter());

    // a module's package (which imports another of the module's), and a main package
    std::println("{} {} {}", sh::Area(2.0, 3.0), sh::Label(2.0, 3.0), tool::Version());
}

fn main() -> !void {
    try run();
}
// expect: dist 5 norm 5
// expect: scaled 6 8 mid 3 4
// expect: 1.2 10 0.5
// expect: color red green
// expect: pixel 2 green
// expect: QUIET a-b-c
// expect: sum 7
// expect: doubled 2 4 6
// expect: squares 4 last 16
// expect: words 3 ccc
// expect: find 2 true
// expect: parse 42
// expect: bad ERROR(strconv.Atoi: parsing "x": invalid syntax)
// expect: perimeter 12 17 tri with 3 sides
// expect: side 4
// expect: missing ERROR(no side 9)
// expect: longest quad with 4 sides 18
// expect: 6 6 m² tool 3
