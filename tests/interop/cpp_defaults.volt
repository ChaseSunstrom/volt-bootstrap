// Default arguments from a parameter's own tokens: an array reference, a std::array and a plain
// decltype have none; an alias's reference, an expression and a decltype followed by = have one
use std::io;
use { "defaults.hpp" } as cpp;
fn main() -> void {
    var xs: i32[3] = { 1, 2, 3 };
    std::println("ref {} {}", cpp::df::ref_plain(&xs), cpp::df::ref_alias(&xs));
    std::println("alias {}", cpp::df::ref_alias());
    std::println("expr {} {}", cpp::df::expr(), cpp::df::expr(5));
    std::println("dt {} {}", cpp::df::dt(), cpp::df::dt(1));
    std::println("cmp {} {}", cpp::df::cmp(), cpp::df::cmp(false));
    std::println("plain {}", cpp::df::dt_plain(4));
    std::println("tp {}", cpp::df::tp(5));
    std::println("tail {}", cpp::df::tail_def());
}
