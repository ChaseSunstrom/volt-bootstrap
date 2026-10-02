// a global initialized from another constant global, a C macro constant included: the C backend
// writes the other global's initializer there, since C wants a constant expression (T-0141)
use std::io;
use { "c_import.h" } as local;

val base: i32 = 40;
val same: i32 = base;
val answer: i32 = local::ANSWER;
val scale: f64 = local::SCALE;
val same_again: i32 = same;

fn main() -> void {
    std::println("{} {} {} {} {}", same, answer, scale, same_again, base + answer);
}
// expect: 40 42 2.5 40 82
