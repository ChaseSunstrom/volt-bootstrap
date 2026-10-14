// an int(&)[3] parameter takes a Volt i32[3]&: another size is a type error
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    var ys: i32[4] = { 1, 2, 3, 4 };
    cpp::pr::fill(&ys, 1);
}
