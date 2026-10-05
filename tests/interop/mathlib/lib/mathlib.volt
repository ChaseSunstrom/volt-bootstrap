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
