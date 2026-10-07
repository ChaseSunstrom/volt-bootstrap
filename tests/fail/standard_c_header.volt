@attributes([@standard("c++17")])
use { "stdio.h" } as c;

fn main() -> void {}
// error: @standard: c++17 is a C++ standard, and these are C headers
