// an early exit in an argument of @cpp<cpp_error!R> (a template taking a Volt std::string) leaves
// before catch mode starts, so a later throw through a plain form still stops the program
use std::io;
use { "params.hpp" } as cpp;
fn early(t: std::string&, k: i32?) -> void {
    val n = @cpp<cpp::cpp_error!i32, std::string>("pr::gs::grow<{t0}>({0}, {1})", t, k ?? return) catch |e| {
        std::println("caught {}", e);
        return;
    };
    std::println("grew {}", n);
}
fn main() -> void {
    var t = std::string::from("a");
    early(&t, null);
    val n = @cpp<i32>("pr::pu::nonneg({0})", -1);
    std::println("not reached {}", n);
}
