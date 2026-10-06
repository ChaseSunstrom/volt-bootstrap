// every alternative of an arm binds the same names
enum shape {
    CIRCLE: f64,
    POINT,
}

fn size(s: shape) -> f64 {
    return match (s) {
        .CIRCLE(r) | .POINT => r,
    };
}

fn main() -> void {}
// error: every alternative binds the same names, and this one doesn't bind 'r'
