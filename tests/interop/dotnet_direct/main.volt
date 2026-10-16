use std::io;
// Volt calling ordinary C# (Geo.cs, nothing in it is written for Volt): the use line is all it
// takes, with voltc run main.volt or in a bolt package. .NET starts on first use
use { "Geo.cs", "Generic.cs" } as geo;

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

    // ref parameters are references (what C# writes comes back); out parameters are results
    var n = 41;
    geo::Gen::Bump(&n);
    var q = geo::Point::new(1.0, 2.0);
    geo::Gen::Shift(&q, 2.0);
    var sh = geo::Shape::new();
    geo::Gen::Swap(&sh);
    std::println("ref {} {} {}", n, q.X, sh.Name());
    val (ok, v) = geo::Gen::TryParse("12");
    val (bad, none) = geo::Gen::TryParse("x");
    val (whole, frac) = geo::Gen::Split(2.25);
    var k = geo::Counter::new();
    val (more, first) = k.Next(1);
    val (again, second) = k.Next(1);
    std::println("out {} {} {} {} {} {} {} {} {} {} {}", ok, v, bad, none, geo::Gen::Half(9), whole, frac, more, first, again, second);

    // delegates: a Volt fn value goes in (C# may keep it, call it later or on another thread); a
    // delegate comes back as a value with call()
    val xs: f64[3] = { 1.0, 2.0, 3.0 };
    val add = geo::Gen::Adder(40);
    val c3 = geo::Gen::Count(3, || (i: i32) -> void { std::print("[{}]", i); });
    std::println("apply {} count {} fold {} adder {} {}", geo::Gen::Apply(|| (x: i32) -> i32 { return x * 3; }, 5), c3, geo::Gen::Fold(xs[..], || (a: f64, b: f64) -> f64 { return a + b * b; }), add.call(2), add.call(3));
    geo::Gen::Keep(|| (x: i32) -> i32 { return x * 10; });
    std::println("kept {} {} thread {}", geo::Gen::CallKept(4), geo::Gen::CallKept(5), geo::Gen::OnThread(|| (x: i32) -> i32 { return x - 1; }, 8));

    // generic methods and a generic class: each instance the program uses is built
    var bx = geo::Box<i32>::new(3);
    bx.Set(bx.Get() + 4);
    val (has, f0) = geo::Gen::TryFirst<i32>(zs[..]);
    var m = 0;
    geo::Gen::Fill(&m);
    std::println("parse {} fill {} {}", geo::Gen::Parse("5"), m, geo::Tagged::new().Name());
    std::println("max {} {} pick {} first {} {} box {} {} {}", geo::Gen::Max<i32>(3, 9), geo::Gen::Max<std::string>("pear", "apple"), geo::Gen::Pick<f64>(xs[..], 1), has, f0, bx.Value(), bx.Show(), geo::Box<std::string>::new("hi").Get());
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
// expect: ref 42 3 circle
// expect: out true 12 false 0 4 2 0.25 true 0 false 1
// expect: [0][1][2]apply 15 count 3 fold 14 adder 42 43
// expect: kept 40 50 thread 7
// expect: parse 5 fill 99 tagged
// expect: max 9 pear pick 2 first true 5 box 7 Box(7) hi
