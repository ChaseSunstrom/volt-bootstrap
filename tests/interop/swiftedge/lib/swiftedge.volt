// swiftedge: the shapes shapelib doesn't have, for Swift's bindings (tests/interop.rs, bindings_shapes):
// optional text and nullable handles in slices, callbacks taking and giving plain shapes, E!str
// and anyerror callbacks, a trait with E!T, a lent handle and text, closures given back taking
// handles, lists of enums and optionals, E!T of a list, a handle and a trait, and names Swift has
use std::string;

export struct thing {
    n: i64;
}

public struct point {
    x: f64;
    y: f64;
}

public enum color {
    RED,
    GREEN,
    BLUE,
}

public error bad {
    NOPE,
    WORSE,
}

export fn thing_new(n: i64) -> thing {
    return { n: n };
}

export attach fn n(this: thing&) -> i64 {
    return this.n;
}

// named like what frees a Swift object: close_() there
export attach fn close(this: thing&) -> i64 {
    return this.n * 10;
}

export struct tally {
    total: i64;
}

// an init taking a slice (inout in Swift)
export fn tally_new(xs: i64[..]) -> tally {
    var t: i64 = 0;
    for (x) in xs {
        t += x;
    }
    return { total: t };
}

export attach fn total(this: tally&) -> i64 {
    return this.total;
}

// a callback's error Volt catches, with owned text given back
export fn swallow(f: fn(i32) -> bad!i32) -> std::string {
    val x = f(1) catch return std::string::from("caught");
    var s = std::string::from("got ");
    s.append_int(@cast<i64>(x));
    return s;
}

// optional text and nullable handles in slices
export fn count_text(xs: str?[..]) -> i64 {
    var t: i64 = 0;
    for (x) in xs {
        val s = x ?? continue;
        t += @cast<i64>(s.len);
    }
    return t;
}

export fn sum_things(xs: thing*[..]) -> i64 {
    var t: i64 = 0;
    for (x) in xs {
        if (x != null) {
            t += x->n;
        }
    }
    return t;
}

// callbacks with plain shapes
export fn slice_cb(f: fn(i32[..]) -> i32, xs: i32[..]) -> i32 {
    return f(xs);
}

export fn cstr_cb(f: fn(cstr?) -> cstr?) -> i64 {
    val s = f("abc");
    if (s == null) {
        return -1;
    }
    return 1;
}

export fn str_cb(f: fn(i32) -> str) -> i64 {
    val a = f(3);
    return @cast<i64>(a.len);
}

export fn enum_cb(f: fn(color) -> color) -> color {
    return f(color::RED);
}

export fn point_cb(f: fn(point) -> point) -> f64 {
    val p = f({ x: 1.0, y: 2.0 });
    return p.x + p.y;
}

export fn str_result_cb(f: fn(i32) -> bad!str) -> i64 {
    val s = f(1) catch return -1;
    return @cast<i64>(s.len);
}

export fn any_cb(f: fn(i32) -> !i32) -> !i32 {
    return f(1);
}

export fn lent_ptr_cb(f: fn(thing*) -> i64, t: thing*) -> i64 {
    return f(t);
}

// a trait with E!T, a lent handle and text
public trait counter {
    fn close(this) -> i64;
    fn bump(this, by: i64) -> bad!i64;
    fn label(this, t: thing&, prefix: std::string) -> std::string;
    fn first(this) -> str;
}

public struct volt_counter {
    total: i64;
}

attach counter -> volt_counter {
    fn close(this) -> i64 {
        return -this.total;
    }
    fn bump(this, by: i64) -> bad!i64 {
        if (by < 0) {
            return bad::WORSE;
        }
        this.total += by;
        return this.total;
    }
    fn label(this, t: thing&, prefix: std::string) -> std::string {
        var s = std::string::from(prefix.as_str());
        s.append_int(t.n);
        return s;
    }
    fn first(this) -> str {
        return "volt";
    }
}

export fn run_counter(c: counter&, t: thing&) -> bad!i64 {
    val a = try c.bump(2);
    val l = c.label(t, std::string::from("n="));
    val f = c.first();
    return a + @cast<i64>(l.len()) + @cast<i64>(f.len) + c.close();
}

export fn give_counter(c: counter) -> i64 {
    val a = c.bump(5) catch return -1;
    return a;
}

export fn volts_counter() -> counter {
    val v: volt_counter = { total: 0 };
    var c: counter = move v;
    return move c;
}

// closures given back taking text and handles
fn name_it(t: thing&, s: str) -> std::string {
    var out = std::string::from(s);
    out.append_int(t.n);
    return out;
}

fn take_it(t: thing) -> i64 {
    return t.n;
}

export fn namer() -> fn(thing&, str) -> std::string {
    return name_it;
}

export fn taker() -> fn(thing) -> i64 {
    return take_it;
}

// lists of enums, optionals and str
export fn colors() -> std::vec<color> {
    var out: std::vec<color> = {};
    out.push(color::BLUE) catch @panic("oom");
    out.push(color::RED) catch @panic("oom");
    return out;
}

export fn take_colors(xs: std::vec<color>) -> i64 {
    var t: i64 = 0;
    for (x) in xs.items() {
        if (x == color::BLUE) {
            t += 10;
        } else {
            t += 1;
        }
    }
    return t;
}

export fn maybes() -> std::vec<i64?> {
    var out: std::vec<i64?> = {};
    out.push(5) catch @panic("oom");
    out.push(null) catch @panic("oom");
    return out;
}

export fn take_maybes(xs: std::vec<i64?>) -> i64 {
    var t: i64 = 0;
    for (x) in xs.items() {
        t += x ?? 100;
    }
    return t;
}

export fn opt_point(p: point?) -> point? {
    val q = p ?? return null;
    return { x: q.y, y: q.x };
}

export fn opt_color(c: color?) -> color? {
    val d = c ?? return null;
    if (d == color::RED) {
        return color::GREEN;
    }
    return null;
}

export fn maybe_str(b: bool) -> str? {
    if (b) {
        return "yes";
    }
    return null;
}

export fn enum_slice(xs: color[..]) -> i64 {
    return @cast<i64>(xs.len);
}

export fn listy(ok: bool) -> bad!std::vec<std::string> {
    if (!ok) {
        return bad::NOPE;
    }
    var out: std::vec<std::string> = {};
    out.push(std::string::from("a")) catch @panic("oom");
    return out;
}

export fn mk_thing(ok: bool) -> bad!thing {
    if (!ok) {
        return bad::WORSE;
    }
    return thing_new(9);
}

export fn mk_counter(ok: bool) -> bad!counter {
    if (!ok) {
        return bad::NOPE;
    }
    val v: volt_counter = { total: 100 };
    var c: counter = move v;
    return move c;
}

export fn texts_in(xs: std::vec<str>) -> i64 {
    return @cast<i64>(xs.items().len);
}

export fn maybe_thing(t: thing*) -> i64 {
    if (t == null) {
        return -1;
    }
    return t->n;
}

export fn hands(f: fn(thing) -> i64) -> i64 {
    return f(thing_new(3));
}

fn len_of(s: std::string) -> i64 {
    return @cast<i64>(s.len());
}

export fn measurer() -> fn(std::string) -> i64 {
    return len_of;
}
