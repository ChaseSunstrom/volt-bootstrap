// a per-use call C++ can't make: clang's error and notes, not the probe's own follow-on
use std::io;
use { "params.hpp" } as cpp;

fn main() -> i32 {
    std::println("{}", cpp::pr::nv::fold_t(1, "x"));
    return 0;
}
