// cpp_fn_handles.hpp: a named Volt fn for a function pointer taking a class Volt holds by handle (a
// borrowed handle, by const&, & or &&) or a std::string& (a Volt std::string& whose changes go back),
// beside a T& of a number (a Volt T&)
use std::io;
use { "cpp_fn_handles.hpp" } as cpp;

fn size_of(n: cpp::fh::Name) -> i32 { return n.size(); }
fn plus_ten(n: cpp::fh::Name) -> i32 { return n.size() + 10; }
fn renamed(n: cpp::fh::Name, k: i32) -> void {
    if (k == 2) {
        n.set("bb");
    }
}
fn shout(s: std::string&) -> void { s.append("!"); }
fn count_in(n: cpp::fh::Name, c: i32&) -> void { *c += n.size(); }

fn main() -> void {
    std::println("apply {} {}", cpp::fh::apply(size_of, "abc"), cpp::fh::apply(plus_ten, "abc"));
    std::println("moved {}", cpp::fh::moved(size_of));
    std::println("rename {}", cpp::fh::rename(renamed, "a"));
    std::println("shouted {}", cpp::fh::shouted(shout, "hi"));
    std::println("counted {}", cpp::fh::counted(count_in, "abcd"));
    cpp::fh::keep(plus_ten);
    std::println("kept {}", cpp::fh::call_kept("abcd"));
}
