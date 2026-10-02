// a debug build checks every free against the size its block was allocated with (a release build's
// free lists would be corrupted by the mismatch)
fn main() -> !void {
    val a: std::mem::default_allocator = {};
    val p = try a.malloc<i32>(4);
    a.free<i32>(p, 2);
}
// exit: 101
// expect-stderr: a block was given back with a different size than it was allocated with
