// error: a frame can't move
async fn g() -> void { suspend; }
fn main() -> void { val fr = async g(); val other = fr; }
