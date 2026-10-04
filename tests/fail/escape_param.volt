// a parameter taken by value is the function's own too
struct point {
    x: i32;
}

fn f(p: point) -> i32& {
    return &p.x;
}

fn main() -> void {
    val r = f({ x: 1 });
}
// error: can't return a reference to 'p'
