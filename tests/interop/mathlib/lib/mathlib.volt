// mathlib: a Volt library other languages call through the C ABI (tests/interop.rs builds it with
// voltc lib --shared/--static and writes its bindings with voltc bindings)
use std::string;

public struct vec2 {
    x: f64;
    y: f64;
}

public enum color {
    RED,
    GREEN,
    BLUE,
}

public error math_error {
    NEGATIVE,
}

export fn ml_add(a: i32, b: i32) -> i32 {
    return a + b;
}

export fn ml_dot(a: vec2, b: vec2) -> f64 {
    return a.x * b.x + a.y * b.y;
}

export fn ml_scale(v: vec2&, k: f64) -> void {
    v.x *= k;
    v.y *= k;
}

export fn ml_len(s: str) -> usize {
    return s.len;
}

// parameters named like what the bindings' wrappers name their own locals, helpers and types (C++'s r,
// C#'s result, Java's arena, Rust's self, the type vec2...), keywords (None, from, type, typeof) and
// one parameter's locals (name_s): each still gets its own value
export fn ml_clash(r: i32, result: i32, arena: i32, e: i32, self: i32, vec2: i32, ctx: i32, None: i32, from: i32, type: i32, a0: i32, name: str, name_s: i32, typeof: i32) -> i32 {
    return r + 2 * result + 3 * arena + 4 * e + 5 * self + 6 * vec2 + 7 * ctx + 8 * None + 9 * from + 10 * type + 11 * a0 + 12 * @cast<i32>(name.len) + 13 * name_s + 14 * typeof;
}

// fields named like words the bindings' languages keep (Python's from, Rust's type and self, C's
// int): each language still reads and writes them
public struct ml_tags {
    from: i32;
    type: i32;
    self: i32;
    int: i32;
}

export fn ml_tags_make() -> ml_tags {
    return { from: 1, type: 2, self: 3, int: 4 };
}

export fn ml_tags_sum(t: ml_tags) -> i32 {
    return t.from + 2 * t.type + 3 * t.self + 4 * t.int;
}

// numbers Volt writes through a pointer (which can be null) and through a reference: each language
// sees what Volt wrote
export fn ml_bump(p: i32*, q: f64&) -> void {
    if (p != null) {
        *p += 1;
    }
    *q *= 2.0;
}

// a struct with text, an array and a struct in it: other languages pass and get it as any struct
// (the text lent for the call)
public struct ml_label {
    name: str;
    sizes: i32[3];
    at: vec2;
}

// a struct with a pointer in it
public struct ml_holder {
    p: i64*;
    k: i32;
}

export fn ml_label_len(l: ml_label) -> i64 {
    return @cast<i64>(l.name.len) + @cast<i64>(l.sizes[0] + l.sizes[1] + l.sizes[2]) + @cast<i64>(l.at.x);
}

// a label naming what it was given (its text is the parameter's: read it before the call is back)
export fn ml_label_of(name: str, k: i32) -> ml_label {
    return { name: name, sizes: { k, k * 2, k * 3 }, at: { x: 1.5, y: 2.5 } };
}

export fn ml_labels_len(ls: ml_label[..]) -> i64 {
    var t: i64 = 0;
    for (l) in ls {
        t += ml_label_len(l);
    }
    return t;
}

export fn ml_holder_k(h: ml_holder) -> i32 {
    return h.k;
}

// E!T as a parameter: its value, or d when it's an error
export fn ml_or(got: math_error!f64, d: f64) -> f64 {
    return got catch d;
}

// a callback giving a struct with text
export fn ml_ask(f: fn(i32) -> ml_label) -> i64 {
    return ml_label_len(f(4));
}

// a struct with text by reference: Volt changes it in place (its text stays the caller's)
export fn ml_relabel(l: ml_label&, k: i32) -> void {
    l.sizes[0] += k;
}

// structs with text in a list (Volt copies the list; the text stays the caller's)
export fn ml_labels_count(ls: std::vec<ml_label>) -> i64 {
    var t: i64 = 0;
    for (l) in ls.items() {
        t += ml_label_len(l);
    }
    return t;
}

// fields named like the wrappers' own helpers and locals (str, c, k)
public struct ml_note {
    str: str;
    c: i32;
    k: i32;
}

export fn ml_note_len(n: ml_note) -> i64 {
    return @cast<i64>(n.str.len) + @cast<i64>(n.c + n.k);
}

// E!T of a struct with text: its length, or -1 for an error
export fn ml_or_label(got: math_error!ml_label) -> i64 {
    val l = got catch return -1;
    return ml_label_len(l);
}

// a callback giving a slice, called for k = 1..n (each one read before the next call)
export fn ml_sum_given(n: i32, f: fn(i32) -> i64[..]) -> i64 {
    var s: i64 = 0;
    for (k) in 1..n + 1 {
        for (x) in f(k) {
            s += x;
        }
    }
    return s;
}

// a callback giving a slice of structs
export fn ml_area_given(f: fn(i32) -> vec2[..]) -> f64 {
    var s = 0.0;
    for (p) in f(2) {
        s += p.x * p.y;
    }
    return s;
}

// a struct whose text is in an array
public struct ml_pair {
    names: str[2];
    n: i32;
}

// a struct holding structs with text, in an array
public struct ml_shelf {
    labels: ml_label[2];
    k: i32;
}

export fn ml_pair_len(p: ml_pair) -> i64 {
    return @cast<i64>(p.names[0].len + p.names[1].len) + @cast<i64>(p.n);
}

// a pair whose text is the parameters' (copied before the call is back)
export fn ml_pair_of(a: str, b: str) -> ml_pair {
    return { names: { a, b }, n: 1 };
}

export fn ml_shelf_len(s: ml_shelf) -> i64 {
    return ml_label_len(s.labels[0]) + ml_label_len(s.labels[1]) + @cast<i64>(s.k);
}

// a slice of structs with text given back (its text the caller's, copied before the call is back)
export fn ml_labels_back(ls: ml_label[..]) -> ml_label[..] {
    return ls;
}

// arrays by value through a callback: Volt passes one and takes one back
export fn ml_turn(f: fn(i32[3]) -> i32[3]) -> i64 {
    val r = f({ 1, 2, 3 });
    return @cast<i64>(r[0]) * 100 + @cast<i64>(r[1]) * 10 + @cast<i64>(r[2]);
}

// a slice of slices at any depth: Volt sums the numbers and doubles each (what it wrote comes back)
export fn ml_deep(xs: i64[..][..][..]) -> i64 {
    var s: i64 = 0;
    for (a) in xs {
        for (b) in a {
            for (i) in 0..b.len {
                s += b[i];
                b[i] *= 2;
            }
        }
    }
    return s;
}

// a callback giving a slice of text, called twice (each one read before the next call)
export fn ml_text_given(f: fn(i32) -> str[..]) -> i64 {
    var n: i64 = 0;
    for (k) in 1..3 {
        for (w) in f(k) {
            n += @cast<i64>(w.len);
        }
    }
    return n;
}

// a callback giving a slice of structs with text
export fn ml_labels_given(f: fn(i32) -> ml_label[..]) -> i64 {
    var n: i64 = 0;
    for (l) in f(2) {
        n += ml_label_len(l);
    }
    return n;
}

// text in a slice of slices
export fn ml_words(ws: str[..][..]) -> i64 {
    var n: i64 = 0;
    for (r) in ws {
        for (w) in r {
            n += @cast<i64>(w.len);
        }
    }
    return n;
}

export fn ml_next(c: color) -> color {
    match (c) {
        .RED => { return color::GREEN; },
        .GREEN => { return color::BLUE; },
        .BLUE => { return color::RED; },
    }
}

export fn ml_sqrt(x: f64) -> math_error!f64 {
    if (x < 0.0) {
        return math_error::NEGATIVE;
    }
    var r = x;
    for (i) in 0..60 {
        if (r == 0.0) {
            break;
        }
        r = (r + x / r) / 2.0;
    }
    return r;
}

// owned text out: other languages get the text and free it
export fn ml_greet(name: str) -> std::string {
    var s = std::string::from("hello, ");
    s.append(name);
    return move s;
}

// owned text, or an error
export fn ml_repeat(s: str, n: i32) -> math_error!std::string {
    if (n < 0) {
        return math_error::NEGATIVE;
    }
    var out = std::string::from("");
    for (i) in 0..n {
        out.append(s);
    }
    return move out;
}

// a slice in
export fn ml_sum(xs: f64[..]) -> f64 {
    var total = 0.0;
    for (x) in xs {
        total += x;
    }
    return total;
}

// an optional out
export fn ml_find(xs: i32[..], x: i32) -> usize? {
    for (i) in 0..xs.len {
        if (xs[i] == x) {
            return i;
        }
    }
    return null;
}

// a callback: other languages pass a function and their own data
export fn ml_each(xs: i32[..], f: fn(i32) -> void) -> void {
    for (x) in xs {
        f(x);
    }
}

// a class: other languages hold a counter by a handle, call its methods, and free it
export struct counter {
    name: std::string;
    count: i64;
}

export fn counter_new(name: str) -> counter {
    return { name: std::string::from(name), count: 0 };
}

export fn counter_add(c: counter&, by: i64) -> i64 {
    c.count += by;
    return c.count;
}

export fn counter_take(c: counter&, by: i64) -> math_error!i64 {
    if (by > c.count) {
        return math_error::NEGATIVE;
    }
    c.count -= by;
    return c.count;
}

export fn counter_name(c: counter&) -> str {
    return c.name.as_str();
}

// arrays by value through a trait other languages implement: Volt passes one and takes one back
public trait ml_turner {
    fn turn(this, a: i32[3]) -> i32[3];
}

// (Volt's own turner: a trait needs a type)
public struct ml_spin {
    k: i32;
}

attach ml_turner -> ml_spin {
    fn turn(this, a: i32[3]) -> i32[3] {
        return { a[1], a[2], a[0] };
    }
}

export fn ml_turned(t: ml_turner&) -> i64 {
    val r = t.turn({ 1, 2, 3 });
    return @cast<i64>(r[0]) * 100 + @cast<i64>(r[1]) * 10 + @cast<i64>(r[2]);
}

// and through an extern "C" fn type, which Volt calls with no glue between: Volt gives one out
// (ml_flipper) and calls the one it's given
extern "C" fn ml_flip(a: i32[3]) -> i32[3] {
    return { a[2], a[1], a[0] };
}

export fn ml_flipper() -> extern "C" fn(i32[3]) -> i32[3] {
    return ml_flip;
}

export fn ml_flipped(f: extern "C" fn(i32[3]) -> i32[3]) -> i64 {
    val r = f({ 4, 5, 6 });
    return @cast<i64>(r[0]) * 100 + @cast<i64>(r[1]) * 10 + @cast<i64>(r[2]);
}
