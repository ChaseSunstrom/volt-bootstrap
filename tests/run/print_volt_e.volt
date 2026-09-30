// print lowering names its output stream VOLT_E in the generated C; text and names that contain
// VOLT_E must come through untouched
use std::io;

fn main() -> void {
    std::println("VOLT_E and {}", 1);
    val VOLT_Ex = 5;
    std::println("{}", VOLT_Ex);
}
// expect: VOLT_E and 1
// expect: 5
