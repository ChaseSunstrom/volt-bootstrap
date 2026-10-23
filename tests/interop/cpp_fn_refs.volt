// cpp_fn_refs.hpp: a closure for a std::function taking a std::string& (a Volt std::string& whose
// changes go back), a T& of a number or of a class Volt lays out (a Volt reference to C++'s), a class
// held by handle (a borrowed handle, by const& or &), a T&& (as a const T&), or giving one back
use std::io;
use { "cpp_fn_refs.hpp" } as cpp;
fn main() -> void {
    std::println("shout {}", cpp::fr::shout("hi", || (s: std::string&) -> void { s.append("!"); }));
    std::println("measure {}", cpp::fr::measure(|| (s: cpp::fr::Shape) -> i32 { return s.area() + 1; }));
    std::println("made {}", cpp::fr::made(|| (k: i32) -> cpp::fr::Shape { return cpp::fr::Shape::new("tri", k); }));
    std::println("twice {}", cpp::fr::twice_in(|| (x: i32&) -> void { *x += 10; }));
    std::println("renamed {}", cpp::fr::renamed(|| (s: cpp::fr::Shape) -> void { s.rename("b"); }));
    std::println("moved {}", cpp::fr::moved(|| (c: cpp::fr::cell&) -> void { c.x = 7; }));
    std::println("taken {}", cpp::fr::taken(|| (s: str) -> i32 { return @cast<i32>(s.len); }));
}
