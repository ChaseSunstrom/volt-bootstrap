// nor inside a struct it returns
struct holder {
    r: i32&;
}

fn f() -> holder {
    var x = 1;
    return { r: &x };
}

fn main() -> void {
    val h = f();
}
// error: can't return a reference to 'x'
