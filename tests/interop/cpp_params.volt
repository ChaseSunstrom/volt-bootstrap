// C++ parameters with a Volt form of their own, declared and in calls worked out per use: a
// reference to an array (const or not, through an alias with a default) takes a Volt array, a
// function pointer a Volt fn, a std::string& a Volt std::string& (C++ changes a copy, which a throw
// leaves out), and a std::function over classes a Volt closure (one held by handle borrowed, a
// move-only one too, one laid out a copy), and a parameter written as an array a Volt pointer
use std::io;
use { "params.hpp" } as cpp;
fn inc(x: i32) -> i32 { return x + 1; }
fn mul(a: f64, b: f64) -> f64 { return a * b; }
fn main() -> void {
    var xs: i32[3] = { 1, 2, 3 };
    std::println("sum {}", cpp::pr::sum(xs));
    cpp::pr::fill(&xs, 4);
    std::println("fill {} {} {}", xs[0], xs[1], xs[2]);
    std::println("total {}", cpp::pr::total(xs));
    cpp::pr::twice(&xs);
    std::println("twice {} {}", xs[0], cpp::pr::sum(xs));
    std::println("first {} {}", cpp::pr::first_of(), cpp::pr::first_of(&xs));
    std::println("apply {} {} {}", cpp::pr::apply(inc, 4), cpp::pr::fold(mul, 1.5, 4.0), cpp::pr::apply_t(inc, 9));
    std::println("@cpp {}", @cpp("pr::apply({0}, {1})", inc, 41));
    var t = std::string::from("hi");
    cpp::pr::shout(&t, 2);
    std::println("shout {}", t);
    grown(&t, 2);
    grown(&t, -1);
    @cpp("pr::shout({0}, {1})", &t, 1);
    std::println("@cpp {}", t);
    relayed(&t);
    var sides = 0;
    val shapes = cpp::pr::each_shape(|sides&| (s: cpp::pr::Shape) -> void { sides += s.sides(); });
    std::println("shapes {} {}", shapes, sides);
    val far = cpp::pr::far(|| (k: i32) -> cpp::pr::point { return { x: k * 10, y: k }; });
    std::println("points {} {}", cpp::pr::sum_points(|| (p: cpp::pr::point) -> i32 { return p.x * p.y; }), far);
    std::println("spend {}", cpp::pr::spend(|| (k: cpp::pr::Token) -> i32 { return k.value(); }));
    var asked = std::string::from("why");
    cpp::pr::exclaimer(2).call(&asked);
    std::println("asked {}", asked);
    var c = std::string::from("ab");
    val k = cpp::pr::count_up(&c);
    std::println("counted {} {} {}", k.n, k.total, c);
    // parameters written as arrays take a Volt pointer, declared and per use
    var ys: i32[3] = { 1, 2, 3 };
    val s3 = cpp::pr::ap::sum3(&ys[0]);
    std::println("arrays {} {} {} {} {}", s3, ys[2], cpp::pr::ap::total(&ys[0], 3), cpp::pr::ap::tail(), cpp::pr::ap::tail(&ys[0]));
    // per use a Volt i32* is C++'s int * (&ys[0] alone would be an int &)
    val p: i32* = &ys[0];
    val c3 = @cpp<i32>("pr::ap::sum3({0})", p);
    std::println("@cpp {} {} {}", c3, @cpp<i32>("pr::ap::tail({0})", p), cpp::pr::ap::head(p));
    var cs: cpp::pr::ap::cell[2] = { { x: 1, y: 2 }, { x: 3, y: 4 } };
    std::println("alias {} cells {}", cpp::pr::ap::sum_alias(&ys[0]), cpp::pr::ap::cells(&cs[0], 2));
    // a template written against a C++ string takes a Volt std::string as one: S& changes it, const
    // S& and S read it; one instantiated with it and with an i32, one with a second parameter
    var w = std::string::from("hey");
    cpp::pr::gs::wrap(&w);
    std::println("wrap {} {} {}", w, cpp::pr::gs::len(&w), cpp::pr::gs::bump(&w));
    std::println("gauge {} {} {}", cpp::pr::gs::gauge(&w), cpp::pr::gs::gauge(7), w);
    val padded = cpp::pr::gs::pad(&w, 2);
    std::println("pad {} {}", padded, w);
    grown_t(&w, 1);
    grown_t(&w, -1);
    // nested std::vectors take nested Volt slices, each level copied (an empty inner one, three deep)
    var r0: i32[2] = { 1, 2 };
    var r1: i32[1] = { 3 };
    var rs: i32[..][3] = { r0[0..2], r1[0..1], r1[0..0] };
    var deep: i32[..][..][2] = { rs[0..3], rs[0..1] };
    std::println("nested {} {} {} {}", cpp::pr::nv::shape(rs[0..3]), cpp::pr::nv::shape_ref(rs[0..2]), cpp::pr::nv::shape3(deep[0..2]), cpp::pr::nv::shape3(deep[0..0]));
}
// a throwing template leaves the Volt string as it was
fn grown_t(t: std::string&, k: i32) -> void {
    val n = cpp::pr::gs::try_grow(t, k) catch |e| {
        std::println("tgrow {}: {} {}", k, e, t.as_str());
        return;
    };
    std::println("tgrow {}: {} {}", k, n, t.as_str());
}
// a throw leaves the Volt string as it was (C++ changed its copy first)
fn grown(t: std::string&, k: i32) -> void {
    val n = cpp::pr::try_grow(t, k) catch |e| {
        std::println("grow {}: {} {}", k, e, t.as_str());
        return;
    };
    std::println("grow {}: {} {}", k, n, t.as_str());
}
// a per-use call's throw under a callback goes back to the C++ that called the callback (its try_
// form's error), the Volt string as it was
fn relayed(t: std::string&) -> void {
    val n = cpp::pr::try_relay(|t| (k: i32) -> i32 { return @cpp("pr::grow({0}, {1})", t, k); }) catch |e| {
        std::println("relay {} {}", e, t.as_str());
        return;
    };
    std::println("relay {}", n);
}
