use std::io;
// Volt calling ordinary Java (nothing in it is written for Volt): the use line is all it takes,
// with voltc run main.volt or in a bolt package. The JVM starts on first use
use { "geo/Point.java", "geo/Shape.java", "geo/Circle.java", "geo/Color.java", "geo/Geom.java", "geo/Generic.java" } as geo;

fn run() -> geo::java_error!void {
    // constructors (overloaded), fields and methods; a static field
    var p = geo::Point::new(3.0, 4.0);
    val o = geo::Point::new();
    std::println("dist {} x {} dims {}", p.dist(&o), p.x(), geo::Point::DIMS());
    p.scale(2.0);
    p.set_y(1.5);
    std::println("scaled {} {} {}", p.x(), p.y(), p.toString());
    val q = p.scaled(0.5);
    std::println("{} made {}", q.toString(), geo::Point::made());

    // a declared exception is a java_error
    std::println("parsed {}", (try geo::Point::parse("1, 2")).toString());
    val bad = geo::Point::parse("x, 1");
    if (bad.err) {
        std::println("bad {}", bad.err);
    }

    // an interface, its default method, and a class as one of its supertypes
    val c = geo::Circle::new(2.0);
    std::println("{} {} {}", c.area(), c.name(), c.describe());
    val s1 = c.as_Shape();
    val s2 = c.as_Shape();
    std::println("total {}", geo::Geom::totalArea(&s1, &s2));

    // enums, their methods, and an enum field
    val col = geo::Color::GREEN.next();
    std::println("color {} {} {} {}", col.lower(), geo::Geom::mix(geo::Color::RED, geo::Color::RED).lower(), c.color().lower(), col.code());

    // primitives, strings, arrays
    std::println("{} {} {}", geo::Geom::add(2, 40), geo::Geom::big(3), geo::Geom::upper("quiet"));
    val xs: f64[3] = { 1.5, 2.5, 3.0 };
    std::println("sum {}", geo::Geom::sum(xs[..]));
    var ys: i32[3] = { 1, 2, 3 };
    geo::Geom::doubleAll(ys[..]);
    std::println("doubled {} {} {}", ys[0], ys[1], ys[2]);
    val sq = geo::Geom::squares(4);
    std::println("squares {} last {}", sq.len, *sq.at(3));
    val parts: str[3] = { "a", "b", "c" };
    val w = geo::Geom::words(" x yy  zzz ");
    std::println("{} words {} {}", geo::Geom::join(parts[..], "-"), w.len, *w.at(2));
    std::println("first {} even {} count {}", geo::Geom::first("volt"), geo::Geom::even(4), geo::Geom::count(ys[..]));
    std::println("parse {} origin {}", try geo::Geom::parseInt(" 42 "), geo::Geom::origin().is_null());

    // collections cross as copies: a List or Set is a slice going in and a std::vec coming out, a Map
    // a std::map
    val nums: i32[3] = { 1, 2, 4 };
    val ws = geo::Generic::words(" b a b ");
    std::println("total {} words {} {}", geo::Generic::total(nums[..]), ws.len, ws.at(2).as_str());
    val names: str[3] = { "bb", "a", "bb" };
    val un = geo::Generic::unique(names[..]);
    val lens = geo::Generic::lengths(names[..]);
    std::println("unique {} {} lengths {} {}", un.len, un.at(0).as_str(), lens.len, geo::Generic::sumValues(&lens));
    val pts: geo::Point[2] = { geo::Point::new(3.0, 4.0), geo::Point::new(6.0, 8.0) };
    std::println("farthest {}", geo::Generic::farthest(pts[..]));
    // generic methods are Volt generics, their values boxed through Java
    std::println("first {} {} max {} {}", geo::Generic::first(nums[..]), geo::Generic::first(ws.items()).as_str(), geo::Generic::max(3, 9), geo::Generic::max(std::string::from("pear"), std::string::from("apple")).as_str());
    val cs: geo::Color[2] = { geo::Color::RED, geo::Color::BLUE };
    val nx = geo::Generic::cycle(cs[..]);
    std::println("cycle {} {} first point {}", nx.at(0).lower(), nx.at(1).lower(), geo::Generic::first(pts[..]).x());
    // a class the import doesn't have is a java_object: toString(), equals() and is_null()
    val d = geo::Generic::minutes(2);
    val b = geo::Generic::boxed(7);
    std::println("{} {} {} {} {}", d.toString().as_str(), geo::Generic::seconds(&d), b.toString().as_str(), b.equals(&b), d.is_null());
}

fn main() -> !void {
    try run();
}
// expect: dist 5 x 3 dims 2
// expect: scaled 6 1.5 (6.0, 1.5)
// expect: (3.0, 0.75) made 3
// expect: parsed (1.0, 2.0)
// expect: bad THROWN(java.lang.NumberFormatException: For input string: "x")
// expect: 12 circle circle of area 12.0
// expect: total 24
// expect: color blue red red b
// expect: 42 3000000000 QUIET
// expect: sum 7
// expect: doubled 2 4 6
// expect: squares 4 last 16
// expect: a-b-c words 3 zzz
// expect: first 118 even true count 3
// expect: parse 42 origin true
// expect: total 7 words 3 b
// expect: unique 2 a lengths 2 3
// expect: farthest 10
// expect: first 1 b max 9 pear
// expect: cycle green red first point 3
// expect: PT2M 120 7 true false
