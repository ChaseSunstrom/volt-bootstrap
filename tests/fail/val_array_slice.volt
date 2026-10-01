// a val array made into a slice for a fn that writes its elements
fn set(s: i32[..]) -> void {
    s[0] = 9;
}

fn main() -> void {
    val a: i32[3] = { 1, 2, 3 };
    set(a);
}
// error: 'a' is a val, and set changes it (through s): declare it with var
