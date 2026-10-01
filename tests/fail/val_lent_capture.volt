// a closure captures a reference parameter and writes through it
fn wrap(r: i32&) -> void {
    val g = |r| () { *r += 1; };
    g();
}

fn main() -> void {
    val x = 0;
    wrap(&x);
}
// error: 'x' is a val, and wrap changes it (through r): declare it with var
