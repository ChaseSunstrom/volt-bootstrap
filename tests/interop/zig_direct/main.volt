use std::io;
// Volt calling an ordinary Zig file (fastmath.zig, nothing in it is written for Volt): the use
// line is all it takes, with voltc run main.volt or in a bolt package
use { "fastmath.zig" } as fm;
// Zig's other kinds of types, and an extern fn whose symbol impl.zig exports
use { "kinds.zig" } as kd;
use { "impl.zig" } as im;

fn kinds() -> void {
    // a packed struct: a Volt struct, its odd-width fields in the next Volt integer up
    var f: kd::Flags = { a: true, b: 5, c: -3 };
    f.c = -60;
    val g = kd::makeFlags(-2);
    std::println("packed {} {} {} {} {}", f.b, f.c, kd::flagsSum(f), g.b, g.c);

    // a tagged union: a handle, made per variant, read by its tag and as_ reads
    var s = kd::Shape::circle(2.0);
    val r = kd::Shape::rect({ w: 2.0, h: 3.0 });
    val n = kd::Shape::none();
    s.grow(2.0);
    std::println("union {} {} {} {} {}", s.tag() == kd::Shape_tag::circle, s.as_circle() ?? 0.0, r.as_circle() == null, (r.as_rect() ?? {}).h, n.tag() == kd::Shape_tag::none);
    val held = kd::Held::buf(kd::Buf::init(3));
    val empty = kd::Held::empty();
    std::println("held {} {}", kd::heldLen(&held), kd::heldLen(&empty));
    std::println("area {} {} round {} {}", kd::shapeArea(&s), kd::shapeArea(&r), s.isRound(), r.isRound());

    // a bare union: a handle with a reader and a setter per field
    var b = kd::Bits::i(7);
    std::println("bits {}", b.i());
    b.set_f(1.5);
    std::println("bits {} {}", b.f(), kd::bitsOf(2.5).f());

    // an opaque type: Zig's pointers, borrowed (Zig makes and frees them)
    val c = kd::ctxCreate(1);
    kd::ctxAdd(&c, 4);
    std::println("ctx {} {} {}", kd::ctxTotal(&c), kd::ctxMaybe(false) == null, kd::zig_ext_total(&c));
    kd::ctxDestroy(&c);
    if (val m = kd::ctxMaybe(true)) {
        std::println("maybe {}", kd::ctxTotal(&m));
        kd::ctxDestroy(&m);
    }

    // an extern fn: the C symbol, linked from impl.zig
    std::println("extern {}", kd::zig_ext_add(2, 3));
}

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

    // generics: comptime types, anytype, a comptime number and fns making types, each instance
    // built by zig as the program uses it
    val ws: i32[3] = { 4, 9, 2 };
    val fs: f64[2] = { 0.5, 2.5 };
    std::println("largest {} {}", fm::largest(ws[..]), fm::largest<f64>(fs[..]));
    std::println("bigger {} {} times {} scaled {} {}", fm::biggerOf(3, 8), fm::biggerOf(2.5, 1.5), fm::times<3>(7), fm::scaled<4>(5), fm::scaled<-2>(5));
    val pr: fm::Pair<i32> = { a: 2, b: 5 };
    std::println("pair {}", pr.sum());
    var st = try fm::Stack<u8>::init(2);
    val p1 = st.push(1);
    val p2 = st.push(2);
    val p3 = st.push(3);
    val total = st.total();
    std::println("stack {} {} {} total {} pop {} {} {}", p1, p2, p3, total, st.pop() ?? 0, st.pop() ?? 0, st.pop() == null);
    var flags = try fm::Stack<bool>::init(1);
    val pushed = flags.push(true);
    std::println("flags {} {}", pushed, flags.pop() ?? false);
}

fn main() -> !void {
    try run();
    kinds();
}
