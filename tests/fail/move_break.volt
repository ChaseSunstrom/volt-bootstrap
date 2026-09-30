// error: 'b' was moved earlier
fn eat(b: std::mem::box<i32>) -> void {}
fn f(c: bool) -> void {
    val b = i32::new(1) catch return;
    :blk {
        if (c) {
            eat(move b);
            break :blk; // reaches the code after the block with b moved
        }
    }
    eat(move b);
}
fn main() -> void { f(true); }
