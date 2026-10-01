// an x& binding points into the matched place: not into a val
enum shape {
    CIRCLE: i32,
    SQUARE: i32,
}

fn main() -> void {
    val s = shape::CIRCLE(1);
    match (s) {
        .CIRCLE(r&) => { *r = 5; },
        .SQUARE(x) => {},
    }
}
// error: can't assign through this; it reaches a val (or a parameter without var)
