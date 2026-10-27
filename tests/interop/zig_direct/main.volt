use std::io;
// Volt calling an ordinary Zig file (fastmath.zig, nothing in it is written for Volt): the use
// line is all it takes, with voltc run main.volt or in a bolt package
use { "fastmath.zig" } as fm;
// Zig's other kinds of types, and an extern fn whose symbol impl.zig exports
use { "kinds.zig" } as kd;
use { "impl.zig" } as im;

fn kinds() -> void {
    // a packed struct: a Volt struct, its odd-width fields Volt's own (u3, i7)
    var f: kd::Flags = { a: true, b: 5, c: -3 };
    f.c = -60;
    val g = kd::makeFlags(-2);
    std::println("packed {} {} {} {} {}", f.b, f.c, kd::flagsSum(f), g.b, g.c);
    // odd widths cross as themselves: a u24 result and a u3 field wrap at their widths, i7 and u3
    // parameters
    val c24 = kd::rgb24(255, 255, 255);
    std::println("odd {} {} {} {}", kd::rgb24(1, 2, 3), c24 +% 1, kd::widen7(-5, 6), g.b +% 1);

    // a tagged union: a handle, made per variant, read by its tag and as_ reads
    var s = kd::Shape::circle(2.0);
    val r = kd::Shape::rect({ w: 2.0, h: 3.0 });
    val n = kd::Shape::none();
    s.grow(2.0);
    std::println("union {} {} {} {} {}", s.tag() == kd::Shape_tag::circle, s.as_circle() ?? 0.0, r.as_circle() == null, (r.as_rect() ?? {}).h, n.tag() == kd::Shape_tag::none);
    val held = kd::Held::buf(kd::Buf::init(3));
    val empty = kd::Held::empty();
    std::println("held {} {}", kd::heldLen(&held), kd::heldLen(&empty));
    val kept = kd::keptOf(5);
    val kept_none = kd::keptOf(0);
    std::println("kept {} {}", kd::keptLen(&kept), kd::keptLen(&kept_none));
    // a payload that frees what it holds, lent by its as_ read
    val lb = held.as_buf() ?? @panic("no buf");
    std::println("lent {} {} {}", kd::bufLen(&lb), kept.as_buf() != null, kept_none.as_buf() == null);
    // text, a slice, an optional and a pointer: the makers copy them, and the union frees the copy
    val ns: i32[3] = { 1, 2, 3 };
    val nr: kd::Rect = { w: 2.0, h: 3.0 };
    val n1 = kd::Note::text("hello");
    val n2 = kd::Note::nums(ns[..]);
    val n3 = kd::Note::maybe("ab");
    val n4 = kd::Note::maybe(null);
    val n5 = kd::Note::at(nr);
    val nz = kd::noteOf(true);
    val n6 = n1.copy();
    std::println("note {} {} {} {} {} {} {} {}", kd::noteSize(&n1), kd::noteSize(&n2), kd::noteSize(&n3), kd::noteSize(&n4), kd::noteSize(&n5), n1.as_text() ?? std::string::from("?"), nz.as_text() ?? std::string::from("?"), n6.as_text() ?? std::string::from("?"));
    {
        val nd = kd::noteSame(&n1);
        std::print("same {} ", nd.as_text() ?? std::string::from("?"));
    }
    std::println("{}", n1.as_text() ?? std::string::from("?"));
    // a bare union: Volt remembers the field it set, so the next set or the drop frees its payload
    var sl = kd::Slot::text("abc");
    val l1 = kd::slotLen(&sl, 0);
    sl.set_nums(ns[..]);
    val l2 = kd::slotLen(&sl, 1);
    sl.set_buf(kd::Buf::init(4));
    val sb = sl.buf();
    val l3 = kd::bufLen(&sb);
    sl.set_n(9);
    val s2 = kd::Slot::buf(kd::Buf::init(2));
    std::println("slot {} {} {} {} {}", l1, l2, l3, sl.n(), kd::slotLen(&s2, 2));
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
    std::println("extern {} {}", kd::zig_ext_add(2, 3), kd::zig_ext_win(4));
    // a pointer to a number, a fixed array, and slices of the file's struct
    var cnt: i32 = 5;
    kd::bumpBy(&cnt, 3);
    val arr3: f32[3] = { 1.0, 2.0, 3.5 };
    val f3 = kd::firstThree(7);
    var rs: kd::Rect[2] = { { w: 1.0, h: 2.0 }, { w: 3.0, h: 1.0 } };
    val before = kd::totalArea(rs[..]);
    kd::growAll(rs[..]);
    val made = kd::rects(3);
    std::println("zig more {} {} {} {} {} {} {} {}", cnt, kd::peek(&cnt), kd::sumThree(arr3[..]), f3[2], before, rs[0].w, made.len, made[2].w);
    // a C string, a many-item pointer, a vector and a tuple struct
    var many: i32[3] = { 1, 2, 3 };
    val mp: i32* = &many[0];
    val s6 = kd::sumMany(mp, 3);
    kd::fillMany(mp, 2, 9);
    val a3: f32[3] = { 1.0, 2.0, 3.0 };
    val b3: f32[3] = { 4.0, 5.0, 6.0 };
    val h2: f32[2] = { 3.0, 5.0 };
    val hv = kd::halves(h2[..]);
    val (q, r) = kd::divmod(17, 5);
    val sw = kd::swap((4, 2.5));
    val on = kd::maybeName(true) ?? std::string::from("-");
    val off = kd::maybeName(false) ?? std::string::from("-");
    std::println("zig c {} {} {} {} {} {} {} {} {} {} {} {}", kd::greet("hello"), kd::motto(), s6, many[1], kd::dot(a3[..], b3[..]), hv[1], q, r, sw.0, sw.1, on, off);
    std::println("zig c2 {} {} {}", kd::nameLen("abc"), kd::nameLen(null), kd::shout("hey"));
    // std.ArrayList and the hash maps
    var ev = kd::evensUpTo(6);
    kd::pushSquares(&ev, 3);
    var sq = kd::squaresMap(3);
    sq.put(10, 1);
    var wl = kd::wordLens("ab cde f");
    val cde = wl.get(std::string::from("cde")) ?? @panic("no cde");
    std::println("zig std {} {} {} {} {} {} {}", ev.len, ev[6], kd::listSum(ev.items()), sq.len, kd::mapTotal(&sq), *cde, kd::lenOf(&wl, "f"));
    // fn pointers and maps the call changes
    val step = 3;
    val arr_big: i32[4] = { 1, 5, 2, 7 };
    val twice = kd::applyTwice(|step| (x: i32) -> i32 { return x + step; }, 10);
    val big = kd::countWhere(arr_big[..], |step| (x: i32) -> bool { return x > step; });
    kd::eachWord("zig calls volt", || (w: str) -> void { std::print("<{}>", w); });
    kd::bumpKey(&sq, 2);
    kd::bumpKey(&sq, 20);
    kd::tagWord(&wl, "longer");
    val b2 = sq.get(2) ?? @panic("no 2");
    val lg = wl.get(std::string::from("longer")) ?? @panic("no longer");
    std::println(" zig fn {} {} {} {} {} {}", twice, big, sq.len, *b2, wl.len, *lg);
    // an ArrayList of the file's struct
    val rl = kd::rectList(3);
    std::println("zig list {} {} {}", rl.len, rl[2].w, kd::widest(rl.items()));
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
