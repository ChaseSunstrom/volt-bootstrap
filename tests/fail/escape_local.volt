// a reference to a local can't be returned: the local is gone once the function returns
fn f() -> i32& {
    var x = 1;
    return &x;
}

fn main() -> void {
    val r = f();
}
// error: can't return a reference to 'x'
