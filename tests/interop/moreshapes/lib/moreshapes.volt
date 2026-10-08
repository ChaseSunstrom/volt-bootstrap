// moreshapes: what Ruby calls beyond shapelib (tests/interop.rs builds it with voltc lib --shared
// --leak-check and writes its bindings with voltc bindings --lang ruby): a trait object Volt keeps
// past the call, a trait fn taking a lent handle and giving one, callbacks given handles or giving
// a str, a slice and an E!T passed to a callback, str?, cstr, a list of optionals, a closure given
// back taking a handle, and a list of handles both ways
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

// a handle lent or given, then a callback: Ruby that converting the callback runs (respond_to?)
// can't close the handle under the call
export fn lend_then(t: thing&, f: fn(i64) -> i64) -> i64 {
    return f(t.n);
}

export fn give_then(t: thing, f: fn(i64) -> i64) -> i64 {
    return f(t.n);
}
