// matching *s and writing through an x& binding writes through s
enum shape {
    CIRCLE: i32,
    SQUARE: i32,
}

fn grow(s: shape&) -> void {
    match (*s) {
        .CIRCLE(r&) => { *r += 1; },
        .SQUARE(x&) => { *x += 2; },
    }
}

fn main() -> void {
    var b = shape::SQUARE(1);
    grow(&b);
    val a = shape::CIRCLE(1);
    grow(&a);
}
// error: 'a' is a val, and grow changes it (through s): declare it with var
