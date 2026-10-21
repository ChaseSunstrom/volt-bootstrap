// val_cpp_write_both through a catching @cpp (its result a cpp_error!i32), S written out
use std::io;
use { "val_cpp_write.hpp" } as cpp;

fn g(s: std::string&) -> i32 {
    return @cpp<cpp::cpp_error!i32, std::string>("vw::pick<{t0}>({0})", s) catch |e| { return 0; };
}

fn main() -> void {
    val k = std::string::from("hi");
    std::print("{}", g(&k));
}
// error: 'k' is a val, and g changes it (through s): declare it with var
