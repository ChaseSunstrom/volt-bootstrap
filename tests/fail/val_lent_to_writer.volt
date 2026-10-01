fn bump(r: i32&) -> void {
    *r += 1;
}

fn main() -> void {
    val x = 0;
    bump(&x);
}
// error: 'x' is a val, and bump changes it (through r): declare it with var
