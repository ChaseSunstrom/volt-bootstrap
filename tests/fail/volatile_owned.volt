// @volatile_write stores plain values: a box would be copied without its owner knowing
fn main() -> void {
    var b = i32::new(1) catch return;
    var slot: std::mem::box<i32>* = null;
    @volatile_write(slot, b);
}
// error: @volatile_write takes plain values
