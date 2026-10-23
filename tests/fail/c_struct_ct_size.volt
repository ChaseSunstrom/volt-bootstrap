// error: has no compile-time layout
// a C union is C's to lay out, so its @sizeof is known at run time only (a struct's is known at
// compile time: tests/run/c_sizeof_comptime.volt)
use { "c_struct_ct_size.h" } as c;
comptime fn size() -> usize { return @sizeof(c::cell); }
val N: usize = size();
fn main() -> void { val x: u8[N] = {}; }
