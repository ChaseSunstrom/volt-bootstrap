// an over-aligned class below C++17 (no aligned new): C++ can't make one by new, so it's left out
@attributes([@standard("c++14")])
use { "cpp_leftout.hpp" } as cpp;

fn main() -> void {
    var a = cpp::lo::vec8::new();
}
