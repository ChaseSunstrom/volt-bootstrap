// a call worked out per use whose result would point into the std::vector made from a Volt slice
// for it is an error (that vector is gone once the call returns)
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var xs: i32[3] = { 1, 2, 3 };
    val p = cpp::tc::ptr_t(xs[0..3]);
    std::println("{}", *p);
}
