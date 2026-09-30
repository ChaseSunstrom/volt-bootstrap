fn main() -> !void {
    val b = try i32::new(1);
    // @cast copies the box without telling the ownership rules: two owners, one allocation
    val c = @cast<std::mem::box<i32>>(b);
}
// exit: 101
