use std::io;
// Volt calling an ordinary Rust crate (geom/, nothing in it is written for Volt): the use line is
// all it takes (the language comes from what it names), with voltc run main.volt or in a bolt package
use { "geom" } as geom;

fn run() -> geom::rust_error!void {
    // plain structs by value, and their methods
    val a = geom::Point::new(0.0, 0.0);
    var b: geom::Point = { x: 3.0, y: 4.0 };
    std::println("dist {} norm {}", geom::dist(a, b), b.norm());
    b.scale(2.0);
    std::println("scaled {} {}", b.x, b.y);

    // strings both ways
    std::println("{} {} {}", geom::greet("volt"), geom::shout("quiet"), geom::first_word("first second"));
    std::println("{} {}", geom::NAME, geom::LIMIT);

    // slices and vecs
    val xs: f64[3] = { 1.5, 2.5, 3.0 };
    std::println("sum {}", geom::sum(xs[..]));
    var ys: i32[3] = { 1, 2, 3 };
    geom::double_all(ys[..]);
    std::println("doubled {} {} {}", ys[0], ys[1], ys[2]);
    val sq = geom::squares(4);
    std::println("squares {} last {}", sq.len, *sq.at(3));
    val ws = geom::words("one two  three");
    std::println("words {} {}", ws.len, *ws.at(2));
    val parts: str[3] = { "a", "b", "c" };
    std::println("join {}", geom::join(parts[..], "-"));

    // options
    val zs: i32[3] = { 5, 7, 9 };
    std::println("find {} {}", geom::find(zs[..], 9) ?? 99, geom::find(zs[..], 4) == null);
    std::println("nickname {} {}", geom::nickname(7) ?? std::string::from("none"), geom::nickname(1) == null);
    std::println("or_default {} {}", geom::or_default(5), geom::or_default(null));

    // results: Ok is the value, Err a rust_error
    std::println("parse {}", try geom::parse_num(" 42 "));
    val bad = geom::parse_num("x");
    if (bad.err) {
        std::println("bad {}", bad.err);
    }
    std::println("div {}", geom::checked_div(7, 2) catch |e| -1);
    val zero = geom::checked_div(1, 0);
    if (zero.err) {
        std::println("zero {}", zero.err);
    }

    // a fieldless enum, its method, and a struct holding one
    val c = geom::next_color(geom::Color::Green);
    std::println("color {} {}", c.name(), geom::Color::Green.name());
    var px: geom::Pixel = { at: { x: 1.0, y: 1.0 }, color: geom::Color::Red, mark: 'a' };
    geom::brighten(&px);
    std::println("pixel {} {} {}", px.at.x, px.color.name(), geom::initial(px.mark));

    // a struct with private fields: an owned handle, with methods; copy clones it
    var s = geom::shapes::Shape::new("tri");
    s.add_side(3.0);
    s.add_side(4.0);
    var t = copy s;
    t.add_side(5.0);
    std::println("perimeter {} {} name {}", s.perimeter(), t.perimeter(), s.name());
    std::println("side {}", try s.side(1));
    val missing = s.side(9);
    if (missing.err) {
        std::println("missing {}", missing.err);
    }
    std::println("longest {}", geom::shapes::longest(&s, &t));
    val cen = geom::shapes::centroid(xs[..]);
    std::println("centroid {}", cen.x);
    std::println("consumed {} into {}", geom::shapes::consume(t), s.into_name());

    // a module named like a Volt keyword, parameters named like the glue's locals, and
    // #[non_exhaustive] types
    std::println("problem {} clash {}", geom::error_::make(3).code, geom::clash(1, 2, 3));
    std::println("settings {} mode {}", geom::Settings::new(4).level(), geom::mode_name(geom::Mode::Slow));

    // a type that isn't Clone: moved, never copied
    var k = geom::shapes::Counter::new();
    k.tick();
    std::println("ticks {}", k.tick());
}

fn main() -> !void {
    try run();
}
