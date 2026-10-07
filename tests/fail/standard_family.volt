@attributes([@standard("c11")])
use { "shapes.hpp" } as shapes;

fn main() -> void {}
// error: @standard: c11 is a C standard, and these are C++ headers
