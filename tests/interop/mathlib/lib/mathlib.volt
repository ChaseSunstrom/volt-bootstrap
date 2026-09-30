// mathlib: a Volt library other languages call through the C ABI (tests/interop.rs builds it with
// voltc lib --shared/--static and writes its bindings with voltc bindings)
struct vec2 {
    x: f64;
    y: f64;
}

enum color {
    RED,
    GREEN,
    BLUE,
}

error math_error {
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
