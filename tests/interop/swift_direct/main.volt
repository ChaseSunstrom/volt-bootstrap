use std::io;
// Volt calling ordinary Swift (geometry.swift and things.swift, one module; nothing in them is
// written for Volt): the use line is all it takes
use { "geometry.swift", "things.swift" } as geo;

fn run() -> geo::swift_error!void {
    // a struct of plain stored properties: a Volt struct, by value, with its methods
    var p: geo::Point = { x: 3.0, y: 4.0 };
    std::println("length {} distance {}", p.length(), geo::distance(p, geo::Point::origin()));
    val q = p.scaled(2.0);
    p.shift(1.0, -1.0);
    std::println("scaled {} {} moved {} {}", q.x, q.y, p.x, p.y);
    std::println("{} {} {}", geo::LIMIT, geo::NAME, geo::RATIO);
    std::println("{}", geo::greet("volt", 2));

    // enums: raw values kept, methods and properties
    val c = geo::Color::green;
    std::println("color {} {} next {}", c.name(), @cast<i64>(geo::Color::blue), c.next().name());
    var px: geo::Pixel = { at: { x: 1.0, y: 2.0 }, color: geo::Color::blue };
    geo::brighten(&px);
    std::println("pixel {} {}", px.at.x, px.color.name());

    // a class: a handle; a copy shares the object
    val k = geo::Counter::new("clicks");
    k.bump(2);
    val shared = copy k;
    shared.bump(3);
    std::println("{} {} {}", k.label(), k.count(), shared.count());
    val started = geo::Counter::new_label("again", 40);
    std::println("started {} made {}", started.bump(1), geo::makeCounter("m").count());

    // a struct that isn't plain: a handle; a copy copies the value
    var inv = geo::Inventory::new();
    inv.add("apple");
    var other = copy inv;
    other.add("pear");
    std::println("inventory {} / {}", inv.summary(), other.summary());

    // arrays, optionals and errors
    val xs: f64[3] = { 1.5, 2.5, 3.0 };
    std::println("total {}", geo::total(xs[..]));
    val sq = geo::squares(4);
    std::println("squares {} last {}", sq.len, *sq.at(3));
    val ws = geo::words("one two three");
    val parts: str[2] = { "a", "b" };
    std::println("words {} {} shout {}", ws.len, ws.at(2).as_str(), geo::shout(parts[..]));
    val zs: i32[3] = { 5, 7, 9 };
    std::println("find {} {}", geo::find(zs[..], 9) ?? 99, geo::find(zs[..], 4) == null);
    std::println("or_default {} {}", geo::orDefault(5), geo::orDefault(null));
    std::println("parse {}", try geo::parse(" 42 "));
    val bad = geo::parse("x");
    if (bad.err) {
        std::println("bad {}", bad.err);
    }
}

fn main() -> void {
    run() catch |e| {
        std::println("failed: {}", e);
    };
}
// expect: length 5 distance 25
// expect: scaled 6 8 moved 4 3
// expect: 10 geometry 1.5
// expect: hi volt, hi volt
// expect: color green 7 next blue
// expect: pixel 2 red
// expect: clicks 5 5
// expect: started 41 made 100
// expect: inventory apple / apple+pear
// expect: total 7
// expect: squares 4 last 16
// expect: words 3 three shout A B
// expect: find 2 true
// expect: or_default 5 -1
// expect: parse 42
// expect: bad ERROR(notANumber("x"))
