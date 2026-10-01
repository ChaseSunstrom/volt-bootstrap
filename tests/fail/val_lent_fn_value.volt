// a fn made into a fn value, called with a reference to a val
fn bump(r: i32&) -> void {
    *r += 1;
}

fn main() -> void {
    val x = 0;
    val f: fn(i32&) -> void = bump;
    f(&x);
}
// error: 'x' is a val, and bump (called as a fn(i32&) -> void value) changes it (through r): declare it with var
