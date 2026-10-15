// an over-aligned iterator below C++17 (no aligned new): Volt can't hold it, and C++ can't either
@attributes([@standard("c++14")])
use { "cpp_ranges2.hpp" } as cpp;

fn main() -> void {
    val wr = cpp::r2::wide_range::new(4);
    for (x) in wr {
    }
}
