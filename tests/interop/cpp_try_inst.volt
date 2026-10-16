// a try_ form of a class template instance's method, the only one in its import: cpp_error is there
use std::io;
use { "try_inst.hpp" } as cpp;
fn main() -> void {
    val b = cpp::ti::boxed(5);
    std::println("get {} plain {}", b.get(2), cpp::ti::plain(1));
    val r = b.try_get(-1) catch |e| {
        std::println("try_get {} {}", e, cpp::last_exception());
        return;
    };
    std::println("try_get {}", r);
}
