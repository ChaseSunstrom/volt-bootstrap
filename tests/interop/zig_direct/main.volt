use std::io;
// Volt calling an ordinary Zig file (fastmath.zig, nothing in it is written for Volt): the use
// line is all it takes, with voltc run main.volt or in a bolt package
use zig { "fastmath.zig" } as fm;

fn run() -> fm::zig_error!void {
    // plain structs by value, and their methods
    val a = fm::Point::init(0.0, 0.0);
    var b: fm::Point = { x: 3.0, y: 4.0 };
    std::println("dist {} norm {}", fm::dist(a, b), b.norm());
    b.scale(2.0);
    std::println("scaled {} {}", b.x, b.y);
    std::println("{} {} {} {}", fm::add(2, 40), fm::NAME, fm::LIMIT, fm::RATIO);

    // text and slices: a function given an allocator hands over what it made
    std::println("{} {}", fm::firstWord("first second"), try fm::upper("quiet"));
    val xs: f64[3] = { 1.5, 2.5, 3.0 };
    std::println("sum {}", fm::sum(xs[..]));
    var ys: i32[3] = { 1, 2, 3 };
    fm::doubleAll(ys[..]);
    std::println("doubled {} {} {}", ys[0], ys[1], ys[2]);
    val sq = try fm::squares(4);
    std::println("squares {} last {}", sq.len, *sq.at(3));
    val parts: str[3] = { "a", "b", "c" };
    std::println("join {}", try fm::join(parts[..], "-"));

    // optionals and error unions
    val zs: i32[3] = { 5, 7, 9 };
    std::println("find {} {}", fm::find(zs[..], 9) ?? 99, fm::find(zs[..], 4) == null);
    std::println("or_default {} {}", fm::orDefault(5), fm::orDefault(null));
    std::println("parse {}", try fm::parseNum(" 42 "));
    val bad = fm::parseNum("x");
    if (bad.err) {
        std::println("bad {}", bad.err);
    }
    std::println("div {}", fm::checkedDiv(7, 2) catch |e| -1);
    val zero = fm::checkedDiv(1, 0);
    if (zero.err) {
        std::println("zero {}", zero.err);
    }

    // an enum, its method, and a struct holding one
    val c = fm::nextColor(fm::Color::green);
    std::println("color {} {}", c.name(), fm::Color::green.name());
    var px: fm::Pixel = { at: { x: 1.0, y: 1.0 }, color: fm::Color::red };
    fm::brighten(&px);
    std::println("pixel {} {}", px.at.x, px.color.name());
    std::println("twice {}", fm::util::twice(21));

    // a struct owning memory: a handle; delete calls its deinit
    var s = try fm::shapes::Shape::init("tri");
    try s.addSide(3.0);
    try s.addSide(4.0);
    var t = try fm::shapes::Shape::init("quad");
    try t.addSide(5.0);
    try t.addSide(5.0);
    std::println("perimeter {} {} name {}", s.perimeter(), t.perimeter(), s.getName());
    std::println("side {}", try s.side(1));
    val missing = s.side(9);
    if (missing.err) {
        std::println("missing {}", missing.err);
    }
    std::println("longest {}", fm::shapes::longest(&s, &t));
    std::println("consumed {}", t.consume());

    // no deinit: a handle that copy duplicates
    var k = fm::shapes::Counter::init("clicks");
    k.tick();
    var k2 = copy k;
    k2.tick();
    std::println("ticks {} {}", k.tick(), k2.tick());
}

fn main() -> !void {
    try run();
}
