// error: starts itself with async
async fn g(n: i32) -> i32 {
    if (n == 0) { return 0; }
    val inner = async g(n - 1);
    return await inner;
}
fn main() -> void { g(3); }
