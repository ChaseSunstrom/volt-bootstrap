// a Volt reference parameter passed on to a C++ template's S&& is an error too: C++ would move from
// the caller's value (cpp_rref_lent)
use { "cpp_rref.hpp" } as cpp;
fn pass(s: std::string&) -> i32 {
    return cpp::rr::take(s);
}
fn main() -> void {
    var y = std::string::from("abc");
    val n = pass(&y);
}
// error: 's' is a C++ S&&, which moves from what it's given: pass move x, or copy x to keep x
