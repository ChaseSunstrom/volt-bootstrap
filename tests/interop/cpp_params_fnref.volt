// a fn whose parameter or result is a reference or a C++ class has no C function-pointer form (a
// declared function pointer parameter has none either): an error where a C++ call takes it as one
use std::io;
use { "params.hpp" } as cpp;
fn by_ref(x: i32&) -> i32 { return 1; }
fn by_point(p: cpp::pr::point) -> i32 { return p.x; }
fn first(xs: i32[..]) -> i32& { return &xs[0]; }
fn plain_ref() -> i32 { return cpp::pr::call0(by_ref); }
fn cpp_class() -> i32 { return @cpp<i32>("pr::call0({0})", by_point); }
fn cpp_symbol() -> i32 { return @cpp<i32>("pr::call0({&0})", first); }
fn plain_result() -> i32 { return cpp::pr::call0(first); }
fn cpp_ref() -> i32 { return @cpp<i32>("pr::call0({0})", by_ref); }
fn op_ref() -> i32 { return cpp::pr::rp::Tally<i32>::new(3).op_bitor(by_ref); }
fn main() -> void {
    std::println("{} {} {} {} {}", plain_ref(), cpp_class(), cpp_symbol(), plain_result(), cpp_ref());
}
