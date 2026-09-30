// error: suspend can't go inside something that gives a value
async fn f(x: i32) -> i32 {
    val y = loop { suspend; break x + 1; };
    return y;
}
fn main() -> void { f(1); }
