// @bitcast of something that owns memory: its bits copied would be owned twice
fn main() -> void {
    val b = i64::new(5) catch @panic("oom");
    val n = @bitcast<u64>(b);
}
// error: @bitcast takes plain data
