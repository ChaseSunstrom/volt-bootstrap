// nor to a field of one
struct point {
    x: i32;
}

fn f() -> i32& {
    var p: point = { x: 1 };
    return &p.x;
}

fn main() -> void {
    val r = f();
}
// error: can't return a reference to 'p'
