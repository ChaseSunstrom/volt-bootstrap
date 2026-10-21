// d4::Q's d(double) would be overridden as d_double, but a virtual method of its own has that name:
// d(double) stays C++'s, and an override named d_double is d_double()'s, which takes nothing
use { "../interop/derive4.hpp" } as cpp;
struct t {
    n: i32;
}
attach cpp::d4::Q -> t {
    fn d_double(this, self: cpp::d4::Q&, x: f64) -> i32 { return 1; }
}
fn main() -> void {}
// error: TBD
