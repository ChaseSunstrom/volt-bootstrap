// error: 'b' was moved earlier
fn eat(b: std::mem::box<i32>) -> void {}
fn f(c: bool) -> void {
    val b = i32::new(1) catch return;
    if (c) {
        eat(move b); // falls through: b is gone on this path
    }
    eat(move b);
}
fn main() -> void { f(true); }
