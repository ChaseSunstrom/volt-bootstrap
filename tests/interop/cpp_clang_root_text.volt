// @cpp<R, std::string> (worked out per use) with no C++ import: the C++ standard library's context
// (cpp_root_ctx), not an index into no contexts
use std::io;

fn main() -> void {
    var t = std::string::from("abc");
    val n = @cpp<i32, std::string>("(int){0}.size() + {1}", t, 1);
    std::println("text {}", n);
}
// expect: text 4
