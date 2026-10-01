// a closure that writes through its parameter
fn main() -> void {
    val x = 0;
    val f = || (r: i32&) { *r += 1; };
    f(&x);
}
// error: 'x' is a val, and a closure changes it (through r): declare it with var
