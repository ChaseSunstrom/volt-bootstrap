// a reference to what owns memory given to a by-value template's T stays a reference (T-0595 reads
// through only a reference to a value owning nothing), so a Volt string's is refused as before
use std::string;
use { "cpp_fn_arg_closure.hpp" } as cpp;
fn main() -> void {
    var s = std::string::from("abc");
    val t = cpp::echo(&s);
}
// error: a Volt std::string crosses to C++ as itself (a template's S, S&, const S&, S*, or S as the result), not inside another type or as a reference result: for a std::vector<S>, pass a str[..] of the strings' text
// error: echo<std::string&> is instantiated here
