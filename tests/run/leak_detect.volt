fn main() -> !void {
    val a: std::mem::default_allocator = {};
    val p = try a.malloc<i32>(4);
}
// flags: --leak-check
// exit: 102
