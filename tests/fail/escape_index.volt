// nor to an element of a local array
fn f() -> i32& {
    var a: i32[3] = { 1, 2, 3 };
    return &a[1];
}

fn main() -> void {
    val r = f();
}
// error: can't return a reference to 'a'
