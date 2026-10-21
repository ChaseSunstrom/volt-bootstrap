// a per-use @cpp (a template taking a Volt std::string, and a clang-typed one) in a nested user
// namespace, declared before the imports, the one it needs second: its C++ context is the import
// whose headers it names, not the first one, and its wrapper is compiled in that import's C++ unit
// (the first is read under C++98, where params.hpp doesn't compile)
use std::io;

namespace app::inner {
    fn go() -> i32 {
        var t = std::string::from("ab");
        val n = @cpp<i32, std::string>("pr::gs::grow<{t0}>({0}, {1})", t, 2);
        val m = @cpp("pr::gs::measure({0})", 7);
        return n * 10 + m;
    }
}

@attributes([@standard("c++98")])
use { "cpp_twin.hpp" } as tw;
use { "params.hpp" } as cpp;

fn main() -> void {
    std::println("later {}", app::inner::go());
}
// expect: later 57
