// a splice takes text, a type, a number or a bool
struct point {
    x: i32;
}

comptime fn bad() -> str {
    val p: point = { x: 1 };
    return quote { val y: i32 = $(p); };
}

@emit(bad());

fn main() -> void {}
// error: can't splice a point into code
