// ktshapes: what Kotlin/Native calls beyond shapelib (tests/interop.rs builds it with voltc lib
// --shared --leak-check and writes its bindings with voltc bindings --lang kotlin): a trait object
// Volt keeps past the call, a trait fn taking a lent handle and giving one, callbacks given handles
// or giving a str, a slice, a struct and E!str, a slice and an E!T passed to a callback, str?, cstr,
// lists of optionals and of handles both ways, a closure given back taking a handle, a struct of
// str, cstr, an array, a slice, E!T and an enum, slices of slices, of str? and of enums, E!T of a
// list and of a trait, and members named like Kotlin's own (close)
use std::string;

export struct thing {
    n: i64;
}

var gone: i32 = 0;

attach fn delete(this: thing&) -> void {
    gone += 1;
}

// how many things were deleted
export fn gone_things() -> i32 {
    return gone;
}

export fn thing_new(n: i64) -> thing {
    return { n: n };
}

export attach fn get(this: thing&) -> i64 {
    return this.n;
}

// named like AutoCloseable's close
export attach fn close(this: thing&) -> i64 {
    return this.n * 100;
}

public trait sizer {
    fn size(this, t: thing&) -> i64;
    fn make(this, n: i64) -> thing;
    fn label(this) -> str;
}

// a trait object Volt holds past the call that gave it
export struct holder {
    s: sizer;
}

export fn holder_new(s: sizer) -> holder {
    return { s: move s };
}

export attach fn measure(this: holder&, n: i64) -> i64 {
    val t = this.s.make(n);
    return this.s.size(&t) * 10;
}

export attach fn tag(this: holder&) -> std::string {
    return std::string::from(this.s.label());
}

public struct fixed {
    k: i64;
}

attach sizer -> fixed {
    fn size(this, t: thing&) -> i64 {
        return t.n + this.k;
    }
    fn make(this, n: i64) -> thing {
        return thing_new(n);
    }
    fn label(this) -> str {
        return "fixed";
    }
}

export fn fixed_sizer(k: i64) -> sizer {
    val f: fixed = { k: k };
    var s: sizer = move f;
    return s;
}

// a trait whose fn is named like AutoCloseable's close
public trait stream {
    fn close(this) -> void;
}

attach stream -> fixed {
    fn close(this) -> void {}
}

export fn shut(s: stream&) -> void {
    s.close();
}

// a callback Volt gives handles
export fn each_thing(n: i64, f: fn(thing) -> void) -> void {
    for (i) in 0..n {
        f(thing_new(i));
    }
}

// a callback giving a str
export fn label_of(f: fn(i32) -> str, x: i32) -> std::string {
    return std::string::from(f(x));
}

public error oops {
    BAD,
}

// a slice and an E!T passed to a callback
export fn with_slice(f: fn(i64[..]) -> i64) -> i64 {
    var xs: i64[3] = { 1, 2, 3 };
    return f(xs[0..3]);
}

export fn with_result(f: fn(oops!i64) -> i64, ok: bool) -> i64 {
    if (ok) {
        return f(5);
    }
    return f(oops::BAD);
}

export fn maybe_text(x: bool) -> str? {
    if (x) {
        return "yes";
    }
    return null;
}

export fn cstr_len(c: cstr) -> usize {
    var n: usize = 0;
    while (c[n] != 0) {
        n += 1;
    }
    return n;
}

export fn some_list() -> std::vec<i64?> {
    var out: std::vec<i64?> = {};
    out.push(1) catch @panic("out of memory");
    out.push(null) catch @panic("out of memory");
    return out;
}

// a closure given back, taking a handle
fn thing_n(t: thing&) -> i64 {
    return t.n;
}

export fn getter() -> fn(thing&) -> i64 {
    return thing_n;
}

// handles given in a list, and given back in one
export fn keep_big(xs: std::vec<thing>, min: i64) -> std::vec<thing> {
    var out: std::vec<thing> = {};
    for (x) in xs.items() {
        if (x.n >= min) {
            out.push(thing_new(x.n)) catch @panic("out of memory");
        }
    }
    return out;
}

export fn lend_then(t: thing&, f: fn(i64) -> i64) -> i64 {
    return f(t.n);
}

export fn give_then(t: thing, f: fn(i64) -> i64) -> i64 {
    return f(t.n);
}

// a struct of what crosses inside one (a field named c, like the C struct a binding writes)
public enum hue {
    RED,
    BLUE,
}

public struct rec {
    name: str;
    tag: cstr;
    nums: i32[3];
    xs: f64[..];
    res: oops!i64;
    h: hue;
    c: i32;
}

export fn rec_sum(r: rec) -> i64 {
    return @cast<i64>(r.name.len) + @cast<i64>(r.nums[0] + r.nums[1] + r.nums[2]) + @cast<i64>(r.xs.len) + @cast<i64>(r.c);
}

export fn rec_bump(r: rec&) -> void {
    r.nums[0] += 1;
    r.c = 9;
}

export fn rec_make(f: fn(i64) -> rec) -> i64 {
    val r = f(3);
    return @cast<i64>(r.name.len) + @cast<i64>(r.nums[2]);
}

// slices of slices, of str? and of enums
export fn total2(rows: i64[..][..]) -> i64 {
    var t: i64 = 0;
    for (r) in rows {
        for (x) in r {
            t += x;
        }
    }
    return t;
}

export fn count_text(xs: str?[..]) -> i64 {
    var t: i64 = 0;
    for (x) in xs {
        val s = x ?? continue;
        t += @cast<i64>(s.len);
    }
    return t;
}

export fn blues(xs: hue[..]) -> i64 {
    var n: i64 = 0;
    for (x) in xs {
        if (x == hue::BLUE) {
            n += 1;
        }
    }
    return n;
}

// a parameter named like a slice's fields
export fn first_two(len: i64[..]) -> i64[..] {
    return len[0..2];
}

export fn maybe_get(t: thing*) -> i64 {
    if (t == null) {
        return -1;
    }
    return t->n;
}

// callbacks giving a slice, E!str and text
export fn slice_back(f: fn(i64) -> i64[..]) -> i64 {
    val xs = f(3);
    return @cast<i64>(xs.len);
}

export fn str_result(f: fn(i64) -> oops!str) -> i64 {
    val s = f(1) catch return -1;
    return @cast<i64>(s.len);
}

export fn text_in(f: fn(std::string) -> i64) -> i64 {
    return f(std::string::from("four"));
}

// E!T of a list and of a trait
export fn list_or(ok: bool) -> oops!std::vec<std::string> {
    if (!ok) {
        return oops::BAD;
    }
    var out: std::vec<std::string> = {};
    out.push(std::string::from("a")) catch @panic("out of memory");
    return out;
}

export fn sizer_or(ok: bool) -> oops!sizer {
    if (!ok) {
        return oops::BAD;
    }
    return fixed_sizer(1);
}
