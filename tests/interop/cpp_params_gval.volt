// C++ never writes into a Volt std::string that can't change: a val (through the template's Volt
// generic too) or a temporary for a template that takes only S& is an error, as C++ refuses it
use std::io;
use { "params.hpp" } as cpp;
fn main() -> void {
    val k = std::string::from("cd");
    cpp::pr::gs::wrap(&k);
    @cpp<void, std::string>("pr::gs::wrap<{t0}>({0})", &k);
    std::println("{}", k);
}
fn temporary() -> void {
    @cpp<void, std::string>("pr::gs::wrap<{t0}>({0})", std::string::from("ef"));
}
