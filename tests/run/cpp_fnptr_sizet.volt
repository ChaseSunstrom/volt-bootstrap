// a C++ function pointer type whose parameter is std::size_t takes a Volt fn of a usize (under
// libc++ too, where std::size_t is a using-declaration); two per-use calls passing a cstr and a
// cstr? to one C++ parameter each get a shim of their own Volt types
use std::io;
use { "cpp_fnptr_sizet.hpp" } as cpp;

fn half(n: usize) -> i32 {
    return @cast<i32>(n / 2);
}

fn read(p: usize*) -> i32 {
    return @cast<i32>(*p);
}

fn main() -> void {
    std::println("{} {}", cpp::fp::call_sizer(half, 21), cpp::fp::call_reader(read));
    val t: cstr = "four";
    val o: cstr? = null;
    std::println("{} {}", @cpp<i32>("fp::count({0})", t), @cpp<i32>("fp::count({0})", o));
}
// expect: 21 9
// expect: 4 -1
