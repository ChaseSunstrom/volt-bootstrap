// @cpp<cpp_error!R>'s arguments are worked out before catch mode: a plain @cpp in one that throws
// stops the program (cpp_params_catch.volt has the rest)
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    val n = @cpp<cpp::cpp_error!i32>("pr::pu::nonneg({0})", @cpp<i32>("pr::pu::nonneg({0})", -1)) catch |e| {
        std::println("caught {}", e);
        return;
    };
    std::println("not reached {}", n);
}
