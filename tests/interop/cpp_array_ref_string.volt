// a std::string(&)[N] takes a Volt std::string[N]&: C++ changes copies, which the Volt strings get
// once the call returns, not when it threw (a try_ form leaves them as they were); a const one takes
// a str[N]
use std::io;
use { "cpp_array_ref.hpp" } as cpp;
fn main() -> void {
    var ss: std::string[2] = { std::string::from("ab"), std::string::from("c") };
    cpp::ar::append(&ss, "xy");
    std::println("append {} {}", ss[0].as_str(), ss[1].as_str());
    cpp::ar::try_append_or_throw(&ss, -1) catch |e| {
        std::println("threw {} {}", e, cpp::last_exception());
    };
    std::println("kept {} {}", ss[0].as_str(), ss[1].as_str());
    cpp::ar::try_append_or_throw(&ss, 1) catch |e| {
        std::println("threw {}", e);
    };
    std::println("tried {} {}", ss[0].as_str(), ss[1].as_str());
    val vs: str[2] = { "four", ss[1].as_str() };
    std::println("lengths {}", cpp::ar::lengths(vs));
}
