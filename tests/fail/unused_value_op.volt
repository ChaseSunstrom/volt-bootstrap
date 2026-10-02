// a statement that only computes a value: probably a missing =
fn bump(r: i32&) -> void {
    *r + 1;
}

fn main() -> void {
    var x = 0;
    bump(&x);
}
// error: this value is never used; did you mean += instead of +?
