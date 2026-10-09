use std::io;
// Volt calling ordinary Kotlin (geometry.kt and things.kt, one package; nothing in them is written
// for Volt): the use line is all it takes
use { "geometry.kt", "things.kt" } as geo;

fn main() -> void {
    // a data class of plain properties: a Volt struct, by value, with its methods
    val p: geo::Point = { x: 3.0, y: 4.0 };
    std::println("length {} distance {}", p.length(), geo::distance(p, geo::Point::origin()));
    val q = p.scaled(2.0);
    std::println("scaled {} {}", q.x, q.y);
    std::println("{} {} {}", geo::LIMIT, geo::NAME, geo::RATIO);
    std::println("{}", geo::greet("volt", 2));

    // an enum class: its entries and methods
    val c = geo::Color::GREEN;
    std::println("color {} next {}", c.title(), c.next().title());
    val px = geo::brighten({ at: { x: 1.0, y: 2.0 }, color: geo::Color::BLUE });
    std::println("pixel {} {}", px.at.x, px.color.title());

    // a class: a handle; a copy shares the object
    val k = geo::Counter::new("clicks");
    k.bump(2);
    val shared = copy k;
    shared.bump(3);
    std::println("{} {} {}", k.label(), k.count(), shared.count());
    val started = geo::Counter::new_label("again", 40);
    std::println("started {} made {}", started.bump(1), geo::makeCounter("m").count());
    // an object: its functions
    geo::Registry::add("a");
    std::println("registry {}", geo::Registry::add("b"));

    // lists, nullables and exceptions
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
    std::println("parse {}", geo::parse(" 42 "));
    // an exception: the try_ form gives it as an error (the plain form stops the program)
    val bad = geo::try_parse("x");
    if (bad.err) {
        std::println("caught {}", bad.err);
    }
}
// expect: length 5 distance 25
// expect: scaled 6 8
// expect: 10 geometry 1.5
// expect: hi volt, hi volt
// expect: color green next blue
// expect: pixel 2 red
// expect: clicks 5 5
// expect: started 41 made 100
// expect: registry 2
// expect: total 7
// expect: squares 4 last 16
// expect: words 3 three shout A B
// expect: find 2 true
// expect: or_default 5 -1
// expect: parse 42
// expect: caught PANIC(kotlin.IllegalArgumentException: not a number: x)
