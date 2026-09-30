// error: has no compile-time layout
use { "time.h" } as c;
comptime fn size() -> usize { return @sizeof(c::tm); }
val N: usize = size();
fn main() -> void { val x: u8[N] = {}; }
