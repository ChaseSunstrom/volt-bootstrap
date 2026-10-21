// a C++ template's S&& moves from what it's given: lending it a Volt value (&x) would let C++ empty
// the caller's string, so it's an error saying to pass move x or copy x (cpp_rref_passed: a reference
// parameter passed on)
use { "cpp_rref.hpp" } as cpp;
fn main() -> void {
    var x = std::string::from("hello");
    val n = cpp::rr::take(&x);
}
// error: 's' is a C++ S&&, which moves from what it's given: pass move x, or copy x to keep x
