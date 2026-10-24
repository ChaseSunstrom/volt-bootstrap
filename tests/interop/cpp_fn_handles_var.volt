// cpp_fn_handles.hpp: a fn value held in a variable has no symbol for C++'s thunk: an error naming
// the parameter
use std::io;
use { "cpp_fn_handles.hpp" } as cpp;

fn size_of(n: cpp::fh::Name) -> i32 { return n.size(); }

fn main() -> void {
    val g: extern "C" fn(cpp::fh::Name) -> i32 = size_of;
    std::println("{}", cpp::fh::apply(g, "abc"));
}
