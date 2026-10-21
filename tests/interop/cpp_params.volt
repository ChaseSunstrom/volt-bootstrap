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
    // S& and S read it (S& and const S& a Volt reference, lent to the call); one instantiated with
    // it and with an i32, one with a second parameter
    var w = std::string::from("hey");
    cpp::pr::gs::wrap(&w);
    std::println("wrap {} {} {}", w, cpp::pr::gs::len(&w), cpp::pr::gs::bump(&w));
    val seven: i32 = 7;
    std::println("gauge {} {} {}", cpp::pr::gs::gauge(&w), cpp::pr::gs::gauge(&seven), w);
    // S by value takes a copy, S&& a value moved in (tk gone after)
    var tk = std::string::from("xyz");
    std::println("take {} {}", cpp::pr::gs::bump(copy tk), tk);
    std::println("took {}", cpp::pr::gs::take(move tk));
    // a const S& beside an S&&: &x calls the const S& one (an i32, a string), the S&& one has its
    // suffixed name
    var ln: i32 = 5;
    var ls = std::string::from("q");
    std::println("lend {} {} {} {}", cpp::pr::gs::lend(&ln), cpp::pr::gs::give(&ln), cpp::pr::gs::lend(&ls), cpp::pr::gs::give(&ls));
    std::println("lend moved {} {}", cpp::pr::gs::lend_rref(copy ln), cpp::pr::gs::give_rref(move ls));
    val padded = cpp::pr::gs::pad(&w, 2);
    std::println("pad {} {}", padded, w);
    grown_t(&w, 1);
    grown_t(&w, -1);
    // of an S& / const S& pair, a var runs S& (and is changed), a val and a str const S&, as C++
    // picks, through the template's Volt generic too; a forwarding S&& takes a value (copy m keeps
    // m; &m is an error: cpp_rref_lent); a const S&-only one takes both
    var m = std::string::from("ab");
    val k = std::string::from("cd");
    val w1 = cpp::pr::gs::which(&m);
    val w2 = @cpp<i32, std::string>("pr::gs::which<{t0}>({0})", &k);
    val w3 = @cpp<i32, std::string>("pr::gs::which<{t0}>({0})", "ef");
    val w4 = @cpp<i32, std::string>("pr::gs::which<{t0}>({0})", &m);
    val w5 = cpp::pr::gs::which(&k);
    std::println("which {} {} {} {} {} {} {}", w1, w2, w3, w4, w5, m, k);
    val f1 = cpp::pr::gs::fwd(copy m);
    std::println("fwd {} {} len {} {}", f1, m, cpp::pr::gs::len(&k), cpp::pr::gs::len(&m));
    // nested std::vectors take nested Volt slices, each level copied (an empty inner one, three deep)
    var r0: i32[2] = { 1, 2 };
    var r1: i32[1] = { 3 };
    var rs: i32[..][3] = { r0[0..2], r1[0..1], r1[0..0] };
    var deep: i32[..][..][3] = { rs[0..3], rs[0..0], rs[0..1] };
    std::println("nested {} {} {} {}", cpp::pr::nv::shape(rs[0..3]), cpp::pr::nv::shape_ref(rs[0..2]), cpp::pr::nv::shape3(deep[0..3]), cpp::pr::nv::shape3(deep[0..0]));
    std::println("nested per use {} {}", cpp::pr::nv::rows_t(rs[0..3]), cpp::pr::nv::deep_t(deep[0..3]));
    // by &&, of doubles and of chars
    var d0: f64[2] = { 1.5, 2.25 };
    var d1: f64[1] = { 0.5 };
    var ds: f64[..][2] = { d0[0..2], d1[0..1] };
    var w0: i8[2] = { 104, 105 };
    var w1: i8[3] = { 121, 111, 117 };
    var ws: i8[..][3] = { w0[0..2], w1[0..0], w1[0..3] };
    std::println("nested {} {} {}", cpp::pr::nv::shape_rv(rs[1..3]), cpp::pr::nv::weigh(ds[0..2]), cpp::pr::nv::spell(ws[0..3]));
    // std::map / std::unordered_map take a Volt std::map&: C++ gets a copy (by value, const&, &&,
    // through an alias), the Volt map unchanged; C++ prints in its own order
    var m: std::map<i32, i32> = {};
    m.put(3, 30);
    m.put(1, 10);
    m.put(2, 20);
    val none: std::map<i32, i32> = {};
    var u: std::map<i32, f64> = {};
    u.put(5, 0.5);
    u.put(4, 1.25);
    std::println("map {} {} {} {} {} {}", cpp::pr::mp::dump(&m), cpp::pr::mp::dump(&none), cpp::pr::mp::dump_u(&u), cpp::pr::mp::dump_rv(&m), cpp::pr::mp::dump_a(&m), m.len);
    var s: std::map<std::string, i32> = {};
    s.put(std::string::from("b"), 2);
    s.put(std::string::from("a"), 1);
    var ss: std::map<std::string, std::string> = {};
    ss.put(std::string::from("k"), std::string::from("v w"));
    ss.put(std::string::from(""), std::string::from(""));
    var v: std::map<i32, std::vec<i32>> = {};
    var v1: std::vec<i32> = {};
    v1.push(4) catch |e| { return; };
    v1.push(5) catch |e| { return; };
    v.put(2, move v1);
    v.put(1, {});
    std::println("map {} {} {}", cpp::pr::mp::dump_s(&s), cpp::pr::mp::dump_ss(&ss), cpp::pr::mp::dump_v(&v));
    std::println("map {} {} {} {} {}", cpp::pr::mp::dump(&m), cpp::pr::mp::dump_v(&v), s.len, ss.len, v.len);
    // the handle forms beside them: a stdcxx::map C++ changes (put_in) and reads (dump)
    var hm: cpp::stdcxx::map<i32, i32> = {};
    std::println("map {} {} {}", cpp::pr::mp::put_in(&hm), cpp::pr::mp::dump(&hm), cpp::pr::mp::both(&m));
    picked(&m, 2);
    picked(&m, 9);
    // a Volt reference per use: an lvalue of what it names first, its address when no call takes
    // that (T*: of a variable, an element, a field, written through), a template's S what it names
    var rx: i32 = 4;
    var ra: i32[3] = { 1, 2, 3 };
    var rq: cpp::pr::rp::pt = { x: 5, y: 6 };
    val d1 = cpp::pr::rp::deref(&rx);
    val d2 = cpp::pr::rp::deref(&ra[1]);
    val d3 = cpp::pr::rp::deref(&rq.y);
    std::println("deref {} {} {} {} {} {}", d1, rx, d2, ra[1], d3, rq.y);
    // of f(int&) and f(int*), &x calls f(int&) and a Volt i32* f(int*)
    val rp: i32* = &rx;
    std::println("sum_ptr {} size {} {} {} which {} {}", cpp::pr::rp::sum_ptr(&ra[0], 3), cpp::pr::rp::size_of(&rx), cpp::pr::rp::size_by(&rx), cpp::pr::rp::size_of(&rq), cpp::pr::rp::which(&rx), cpp::pr::rp::which(rp));
    checked_at(&rx);
    rx = -1;
    checked_at(&rx);
    // a declared template's S& a Volt S& (S an i32, what &rt names): C++ changes the Volt variable
    var rt: i32 = 21;
    cpp::pr::rp::twice_ref(&rt);
    // a method's pointer argument beside its receiver: an & method, an operator, an && one
    var tz: i32 = 1;
    val ty = cpp::pr::rp::Tally<i32>::new(3);
    val t1 = ty.add(&tz);
    val t2 = ty.op_add(&tz);
    val t3 = ty.spend(&tz);
    std::println("twice {} tally {} {} {} {}", rt, t1, t2, t3, tz);
    // a class template's T& a Volt T& (laid out; held by handle, per use): &kn lends kn and C++'s
    // write is seen; a laid-out one's const T& takes a value (literals for a constructor's); per use
    // a value runs which(const T&), &kn which(T&)
    var kp: cpp::pr::ct::keep<i32> = { v: 3 };
    var kn: i32 = 1;
    kp.bump(&kn);
    val hd = cpp::pr::ct::held<i32>::new(4);
    hd.bump(&kn);
    std::println("keep {} {} {}", kn, kp.peek(kn), hd.peek(&kn));
    val du = cpp::pr::ct::duo<f64>::new(1.5, 2.75);
    val half: f64 = 0.5;
    std::println("duo {} which {} {}", du.sum(half), hd.which(kn), hd.which(&kn));
}
// a Volt reference parameter read as its address, in a try_ form
fn checked_at(r: i32&) -> void {
    val n = cpp::pr::rp::try_checked(r) catch |e| {
        std::println("checked {}: {}", *r, e);
        return;
    };
    std::println("checked {}: {}", *r, n);
}
// a try_ form taking a Volt std::map: C++'s throw an error
fn picked(m: std::map<i32, i32>&, k: i32) -> void {
    val n = cpp::pr::mp::try_pick_k(m, k) catch |e| {
        std::println("pick {}: {}", k, e);
        return;
    };
    std::println("pick {}: {}", k, n);
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
