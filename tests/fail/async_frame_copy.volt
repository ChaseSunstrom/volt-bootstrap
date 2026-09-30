// error: a frame can't be copied
async fn g() -> void { suspend; }
fn main() -> void { val fr = async g(); val other = copy fr; }
