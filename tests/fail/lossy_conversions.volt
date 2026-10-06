// what could lose a value still takes a cast: an i64 into an f64 (past 2^53), a u32 into an f32
// (past 2^24)
fn wide() -> f64 {
    val big: i64 = 1;
    return big;
}
fn narrow() -> f32 {
    val m: u32 = 1;
    return m;
}
fn main() -> void {
    wide();
    narrow();
}
// error: expected f64, found i64
// error: expected f32, found u32
