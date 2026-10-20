// error: or a defer run by a break or continue from inside an expression: x ?? break
fn maybe(i: i32) -> i32? { return i; }
async fn f() -> i32 {
    for (i) in 0..3 {
        defer { suspend; }
        val x = maybe(i) ?? break;
    }
    return 0;
}
fn main() -> void { f(); }
